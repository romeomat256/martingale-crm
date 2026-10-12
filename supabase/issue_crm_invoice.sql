-- Émission des factures : numérotation continue, acompte et facture finale chaînés au devis.
CREATE OR REPLACE FUNCTION public.issue_crm_invoice(p_request_id uuid, p_document jsonb, p_html text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_user uuid := auth.uid();
  v_series public.crm_invoice_series%rowtype;
  v_existing jsonb;
  v_id uuid := gen_random_uuid();
  v_number bigint;
  v_num text;
  v_now timestamptz;
  v_date date;
  v_details jsonb := p_document->'invoiceDetails';
  v_line jsonb;
  v_sum numeric := 0;
  v_qty numeric := 0;
  v_ht numeric;
  v_vat numeric;
  v_ttc numeric;
  v_rate numeric;
  v_shipping numeric;
  v_discount numeric;
  v_snapshot jsonb;
  v_payload jsonb;
  v_columns text;
  -- Chaînage devis -> acompte(s) -> facture finale
  v_type text := coalesce(p_document->>'type','');
  v_src text := nullif(btrim(coalesce(p_document->>'sourceQuoteNum','')),'');
  v_order_ht numeric;
  v_order_vat numeric;
  v_order_ttc numeric;
  v_pct numeric;
  v_ded_ht numeric := 0;
  v_ded_vat numeric := 0;
  v_ded_ttc numeric := 0;
  v_ded_count int := 0;
  v_cli_ht numeric := 0;
  v_cli_ttc numeric := 0;
  v_cli_count int := 0;
begin
  if v_user is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  if p_request_id is null then raise exception 'Identifiant de demande requis.'; end if;
  select * into v_series from public.crm_invoice_series
    where seller_siren = '928180728' for update;
  if not found then raise exception 'Serie de factures non configuree : confirmer la derniere facture emise.'; end if;
  if not (v_user = any(v_series.allowed_users)) then
    raise exception 'Compte non autorise pour cette serie.' using errcode = '42501';
  end if;
  select invoice_snapshot into v_existing from public.documents
    where user_id = v_user and invoice_request_id = p_request_id;
  if found then return v_existing; end if;
  if coalesce(p_document->>'type','') not in ('FAC','SOL','FDF') then
    raise exception 'Type de facture invalide.';
  end if;
  if coalesce(btrim(p_document->>'contact'),'') = ''
     or coalesce(btrim(p_document->>'billingAddress'),'') = '' then
    raise exception 'Client et adresse de facturation requis.';
  end if;
  if coalesce(v_details#>>'{seller,siren}','') <> '928180728'
     or coalesce((v_details#>>'{seller,capital}')::numeric,0) <= 0 then
    raise exception 'Identite et capital social du vendeur requis.';
  end if;
  if coalesce(v_details->>'operationDate','') !~ '^\d{4}-\d{2}-\d{2}$'
     or coalesce(v_details->>'dueDate','') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'Dates de livraison/acompte et de paiement requises.';
  end if;
  v_now := clock_timestamp();
  if v_series.last_issued_at > v_now then raise exception 'La derniere date de facturation est dans le futur.'; end if;
  v_date := (v_now at time zone 'Europe/Paris')::date;
  perform (v_details->>'operationDate')::date;
  if (v_details->>'dueDate')::date < v_date then
    raise exception 'L echeance ne peut pas preceder la date d emission.';
  end if;
  if coalesce(v_details->>'clientSiren','') <> '' and (v_details->>'clientSiren') !~ '^\d{9}$' then
    raise exception 'SIREN client invalide.';
  end if;
  if jsonb_typeof(p_document->'lineItems') is distinct from 'array'
     or jsonb_array_length(p_document->'lineItems') = 0 then
    raise exception 'Au moins une ligne produit est requise.';
  end if;
  for v_line in select value from jsonb_array_elements(p_document->'lineItems') loop
    if coalesce((v_line->>'qty')::numeric,0) <= 0
       or (v_line->>'qty')::numeric <> trunc((v_line->>'qty')::numeric)
       or coalesce((v_line->>'unitPriceHT')::numeric,-1) < 0
       or coalesce((v_line->>'lineDiscountPct')::numeric,-1) not between 0 and 100
       or coalesce((v_line->>'totalHT')::numeric,-1) < 0 then
      raise exception 'Quantite, prix ou remise invalide.';
    end if;
    if abs((v_line->>'totalHT')::numeric - (v_line->>'qty')::numeric *
       (v_line->>'unitPriceHT')::numeric * (1 - (v_line->>'lineDiscountPct')::numeric / 100)) > 0.02 then
      raise exception 'Total de ligne incoherent.';
    end if;
    v_sum := v_sum + (v_line->>'totalHT')::numeric;
    v_qty := v_qty + (v_line->>'qty')::numeric;
  end loop;
  v_discount := (p_document->>'globalDiscountPct')::numeric;
  v_shipping := (p_document->>'shippingHT')::numeric;
  v_ht := (p_document->>'ht')::numeric;
  v_vat := (p_document->>'tva')::numeric;
  v_ttc := (p_document->>'ttc')::numeric;
  v_rate := (p_document->>'vatRate')::numeric;
  -- Totaux de la commande complète (anciennes versions du CRM : commande = montant facturé)
  v_order_ht := coalesce((p_document->>'orderHT')::numeric, v_ht);
  v_order_vat := coalesce((p_document->>'orderTVA')::numeric, v_vat);
  v_order_ttc := coalesce((p_document->>'orderTTC')::numeric, v_ttc);
  if v_discount is null or v_discount not between 0 and 100
     or v_shipping is null or v_shipping < 0 or v_ht is null or v_ht < 0
     or v_vat is null or v_vat < 0 or v_ttc is null or v_ttc < 0
     or v_order_ht is null or v_order_vat is null or v_order_ttc is null
     or v_rate is null or v_rate not in (0,0.2)
     or coalesce((p_document->>'qty')::numeric,0) <> v_qty
     or abs(v_order_ht - (v_sum * (1 - v_discount / 100) + v_shipping)) > 0.02
     or abs(v_order_vat - v_order_ht * v_rate) > 0.02 or abs(v_order_ttc - v_order_ht - v_order_vat) > 0.02
     or abs(v_ttc - v_ht - v_vat) > 0.02 then
    raise exception 'Totaux de facture incoherents.';
  end if;

  if v_src is not null then
    if v_type not in ('FAC','FDF') then raise exception 'Type de facture invalide pour un devis.'; end if;
    perform 1 from public.documents where num = v_src and type = 'DEV' for update;
    if not found then raise exception 'Devis % introuvable.', v_src; end if;
    if exists (select 1 from public.documents where type = 'FDF'
               and invoice_snapshot->>'sourceQuoteNum' = v_src) then
      raise exception 'Le devis % est deja facture.', v_src;
    end if;
    select coalesce(sum(ht),0), coalesce(sum(tva),0), coalesce(sum(ttc),0), count(*)
      into v_ded_ht, v_ded_vat, v_ded_ttc, v_ded_count
      from public.documents where type = 'FAC' and invoice_snapshot->>'sourceQuoteNum' = v_src;
  end if;

  if v_type = 'FAC' and v_src is not null then
    v_pct := (p_document->>'depositPct')::numeric;
    if v_pct is null or v_pct <= 0 or v_pct >= 100 then raise exception 'Pourcentage d acompte invalide.'; end if;
    if abs(v_ht - round(v_order_ht * v_pct / 100, 2)) > 0.02 or abs(v_vat - v_ht * v_rate) > 0.02 then
      raise exception 'Montant d acompte incoherent.';
    end if;
    if v_ded_ttc + v_ttc > v_order_ttc + 0.02 then
      raise exception 'Les acomptes depassent le montant de la commande.';
    end if;
  elsif v_type = 'FDF' and v_src is not null then
    if jsonb_typeof(coalesce(p_document->'deductions','[]'::jsonb)) <> 'array' then
      raise exception 'Liste des acomptes invalide.';
    end if;
    select coalesce(sum((d->>'ht')::numeric),0), coalesce(sum((d->>'ttc')::numeric),0), count(*)
      into v_cli_ht, v_cli_ttc, v_cli_count
      from jsonb_array_elements(coalesce(p_document->'deductions','[]'::jsonb)) d;
    if v_cli_count <> v_ded_count or abs(v_cli_ht - v_ded_ht) > 0.02 or abs(v_cli_ttc - v_ded_ttc) > 0.02 then
      raise exception 'Acomptes a deduire incomplets : recharger le CRM puis recommencer.';
    end if;
    if abs(v_ht - (v_order_ht - v_ded_ht)) > 0.02 or abs(v_vat - (v_order_vat - v_ded_vat)) > 0.02 then
      raise exception 'Reste a payer incoherent.';
    end if;
  elsif abs(v_order_ht - v_ht) > 0.02 or abs(v_order_vat - v_vat) > 0.02 then
    raise exception 'Totaux de facture incoherents.';
  end if;
  if v_rate = 0 and coalesce(btrim(p_document->>'vatLegalMention'),'') = '' then
    raise exception 'Mention d exoneration de TVA requise.';
  end if;
  if p_html is null or position('__MP_INVOICE_NUMBER__' in p_html) = 0
     or position('__MP_INVOICE_DATE__' in p_html) = 0 or length(p_html) > 2000000 then
    raise exception 'Document imprimable manquant ou invalide.';
  end if;
  v_number := v_series.last_number + 1;
  v_num := v_series.number_prefix || lpad(v_number::text, greatest(v_series.number_width,length(v_number::text)), '0');
  if exists (select 1 from public.documents where num = v_num) then
    raise exception 'Numero deja present : faire verifier la reprise de numerotation.';
  end if;
  v_snapshot := (p_document - 'invoiceHtml' - 'invoiceIssuedAt' - 'id') || jsonb_build_object(
    'id',v_id,'num',v_num,'createdAt',v_now,'date',to_char(v_date,'DD/MM/YYYY'),
    'invoiceIssuedAt',v_now,'invoiceRequestId',p_request_id,'statut','Envoyé',
    'invoiceHtml',replace(replace(p_html,'__MP_INVOICE_NUMBER__',v_num),'__MP_INVOICE_DATE__',to_char(v_date,'DD/MM/YYYY'))
  );
  v_payload := jsonb_build_object(
    'id',v_id,'user_id',v_user,'num',v_num,'type',p_document->>'type',
    'type_label',p_document->>'typeLabel','contact',p_document->>'contact',
    'prod_id',p_document->>'prodId','prod_name',p_document->>'prodName',
    'qty',v_qty,'ht',v_ht,'tva',v_vat,'ttc',v_ttc,'created_at',v_now,'statut','Envoyé',
    'client_name',p_document->>'clientName','company',p_document->>'company',
    'contact_name',p_document->>'contactName','email',p_document->>'email','tel',p_document->>'tel',
    'billing_address',p_document->>'billingAddress','shipping_address',p_document->>'shippingAddress',
    'delivery_dept',p_document->>'deliveryDept','validity',p_document->>'validity',
    'line_items',p_document->'lineItems','subtotal_brut_ht',p_document->'subtotalBrutHT',
    'subtotal_ht',p_document->'subtotalHT','global_discount_pct',v_discount,
    'global_discount_amount_ht',p_document->'globalDiscountAmountHT',
    'shipping_ht',v_shipping,'shipping_mode',p_document->>'shippingMode',
    'shipping_manual_ht',p_document->'shippingManualHT','shipping_auto_ht',p_document->'shippingAutoHT',
    'shipping_details',p_document->>'shippingDetails','is_international',p_document->'isInternational',
    'vat_regime',p_document->>'vatRegime','vat_rate',v_rate,
    'customer_vat_number',p_document->>'customerVatNumber','vat_legal_mention',p_document->>'vatLegalMention',
    'invoice_request_id',p_request_id,'invoice_issued_at',v_now,'invoice_snapshot',v_snapshot
  );
  if coalesce(p_document->>'prospectId','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_payload := v_payload || jsonb_build_object('prospect_id',p_document->>'prospectId');
  end if;
  select string_agg(format('%I',attname),', ' order by attnum) into v_columns
    from pg_attribute where attrelid = 'public.documents'::regclass
      and attnum > 0 and not attisdropped and attgenerated = '' and attidentity = ''
      and v_payload ? attname;
  execute format('insert into public.documents (%s) select %s from jsonb_populate_record(null::public.documents, $1)',v_columns,v_columns)
    using v_payload;
  update public.crm_invoice_series set last_number = v_number, last_issued_at = v_now
    where seller_siren = v_series.seller_siren;
  -- La facture finale scelle le devis.
  if v_type = 'FDF' and v_src is not null then
    update public.documents set statut = 'Facturé' where num = v_src and type = 'DEV';
  end if;
  return v_snapshot;
end;
$function$;
