-- Paiement en deux temps : acompte puis solde.
-- Un devis porte son acompte (doc_meta.depositPct, 50 % par défaut, 0 = paiement intégral).
-- Un virement égal à l'acompte, ou au reste dû quand un acompte est déjà reçu, est rattaché au devis
-- comme un virement du montant exact : seul si le payeur est reconnu, à confirmer sinon.

create or replace function public.crm_quote_deposit_pct(p_meta jsonb)
returns numeric language sql immutable set search_path = pg_catalog, public as $$
  select case when nullif(coalesce(p_meta, '{}'::jsonb) ->> 'depositPct', '') is null then 50
              else least(90, greatest(0, (p_meta ->> 'depositPct')::numeric)) end
$$;

-- Déjà reçu sur un devis : virements rapprochés du devis et de ses factures (hors le virement en cours).
create or replace function public.crm_quote_paid(p_user uuid, p_num text, p_except bigint default null)
returns numeric language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(sum(b.amount), 0) from public.bank_receipts b
   where b.user_id = p_user and b.status = 'rapproche' and b.id <> coalesce(p_except, -1)
     and (b.document_num = p_num
          or b.document_num in (select x.num from public.documents x
                                 where x.user_id = p_user and x.invoice_snapshot ->> 'sourceQuoteNum' = p_num))
$$;

-- Ce virement correspond-il à l'acompte ou au solde de ce devis ? Renvoie 'acompte', 'solde' ou null.
create or replace function public.crm_quote_part(p_user uuid, p_num text, p_ttc numeric, p_meta jsonb, p_amount numeric, p_except bigint default null)
returns text language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_paid numeric; v_pct numeric;
begin
  if coalesce(p_ttc, 0) <= 0 then return null; end if;
  v_paid := public.crm_quote_paid(p_user, p_num, p_except);
  v_pct := public.crm_quote_deposit_pct(p_meta);
  if v_paid <= 0.05 and v_pct > 0 and abs(round(p_ttc * v_pct / 100, 2) - p_amount) <= 0.5 then return 'acompte'; end if;
  if v_paid > 0.05 and abs(p_ttc - v_paid - p_amount) <= 0.5 then return 'solde'; end if;
  return null;
end $$;

create or replace function public.crm_match_receipt(p_id bigint, p_mode text default 'complet')
returns text language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.bank_receipts%rowtype;
  d public.documents%rowtype;
  v_refs text[];
  v_payer text;
  v_alias uuid;
  v_prospect uuid;
  v_ratio numeric;
  v_pct int;
  v_note text;
  v_status text;
  v_kind text;
  v_cands jsonb;
  v_first jsonb;
  v_n int; v_n_named int;
  v_reflabel text;
  i public.documents%rowtype;
  v_viadevis text;
  v_near boolean := false;
  v_part text;
begin
  select * into r from public.bank_receipts where id = p_id for update;
  if not found then return 'introuvable'; end if;
  if r.decided_at is not null or r.applied then return r.status; end if;

  v_payer := public.crm_payer(r.label);
  v_refs := public.crm_extract_refs(r.label);
  v_reflabel := case when array_length(v_refs, 1) > 0 then ' (libellé : ' || array_to_string(v_refs, ', ') || ')' else '' end;

  if r.label ~* '(shopify|stripe|paypal)' then
    update public.bank_receipts set payer = v_payer, status = 'ignore', match_kind = 'site',
      match_note = 'Versement groupé du site (Shopify, Stripe ou PayPal)', prospect_id = null, document_num = null, document_type = null,
      candidates = '[]'::jsonb, updated_at = now() where id = p_id;
    return 'ignore';
  end if;
  if r.amount < 1 then
    update public.bank_receipts set payer = v_payer, status = 'ignore', match_kind = 'site',
      match_note = 'Montant de vérification de compte', candidates = '[]'::jsonb, updated_at = now() where id = p_id;
    return 'ignore';
  end if;

  select prospect_id into v_alias from public.bank_payer_aliases
    where user_id = r.user_id and payer_key = public.crm_norm(v_payer);

  if array_length(v_refs, 1) > 0 then
    select * into d from public.documents
      where user_id = r.user_id and num = any(v_refs)
      order by (invoice_issued_at is not null) desc, abs(ttc - r.amount), created_at desc limit 1;
  end if;

  if d.id is not null then
    if d.type = 'DEV' then
      select x.* into i from public.documents x
        where x.user_id = r.user_id and x.type <> 'DEV' and x.invoice_issued_at is not null and x.statut <> 'Annulée'
          and x.invoice_snapshot ->> 'sourceQuoteNum' = d.num and abs(x.ttc - r.amount) <= 0.05
          and not exists (select 1 from public.bank_receipts b where b.document_num = x.num and b.status = 'rapproche' and b.id <> p_id)
        order by x.created_at desc limit 1;
      if i.id is not null then v_viadevis := d.num; d := i; end if;
    end if;
    v_prospect := d.prospect_id;
    if v_prospect is null or not exists (select 1 from public.prospects p where p.id = v_prospect) then
      select p.id into v_prospect from public.prospects p
        where p.user_id = r.user_id and public.crm_norm(p.name) = public.crm_norm(coalesce(nullif(d.company, ''), nullif(d.client_name, ''), d.contact))
        order by p.date_updated desc limit 1;
    end if;
    v_prospect := coalesce(v_prospect, v_alias);
    v_ratio := case when coalesce(d.ttc, 0) > 0 then r.amount / d.ttc * 100 end;
    v_pct := round(v_ratio, -1)::int;
    v_part := case when d.type = 'DEV' then public.crm_quote_part(r.user_id, d.num, d.ttc, d.doc_meta, r.amount, p_id) end;
    v_note := case
      when abs(r.amount - d.ttc) <= 0.05 then 'Numéro cité dans le libellé, montant identique'
      when v_part = 'solde' then 'Numéro cité dans le libellé, solde du devis'
      when v_ratio is not null and abs(v_ratio - v_pct) <= 0.5 and v_pct between 10 and 90
        then 'Numéro cité dans le libellé, acompte de ' || v_pct || ' %'
      else 'Numéro cité dans le libellé, montant différent du document (' || public.crm_money_fr(d.ttc) || ')' end;
    if v_viadevis is not null then
      v_note := 'Devis ' || v_viadevis || ' cité dans le libellé, facture ' || d.num || ' du même montant';
    end if;
    update public.bank_receipts set payer = v_payer, status = 'rapproche', match_kind = 'reference', match_note = v_note,
      prospect_id = v_prospect, document_num = d.num, document_type = d.type, candidates = '[]'::jsonb, updated_at = now() where id = p_id;
    if p_mode <> 'aucun' then perform public.crm_apply_receipt(p_id, p_mode); end if;
    return 'rapproche';
  end if;

  -- Documents du même montant, ou devis dont ce virement est l'acompte ou le solde.
  select coalesce(jsonb_agg(to_jsonb(q) order by q.named desc, q.created_at desc), '[]'::jsonb) into v_cands
  from (
    select distinct on (coalesce(x.prospect_id::text, public.crm_norm(x.client)))
           x.num, x.type, x.ttc, x.prospect_id, x.client, x.named, x.created_at, x.part
    from (
      select dd.num, dd.type, dd.ttc, dd.created_at, (dd.invoice_issued_at is not null) as issued,
             coalesce(pp.id, pn.id) as prospect_id,
             coalesce(nullif(dd.company, ''), nullif(dd.client_name, ''), dd.contact) as client,
             (public.crm_client_matches(coalesce(pp.name, pn.name), pp.contact, r.label, v_payer) or public.crm_client_matches(dd.company, dd.contact_name, r.label, v_payer) or public.crm_client_matches(dd.client_name, null, r.label, v_payer)
               or (v_alias is not null and v_alias = coalesce(pp.id, pn.id))) as named,
             case when abs(dd.ttc - r.amount) <= 0.05 then null
                  else public.crm_quote_part(r.user_id, dd.num, dd.ttc, dd.doc_meta, r.amount, p_id) end as part
      from public.documents dd
      left join public.prospects pp on pp.id = dd.prospect_id
      left join lateral (
        select p2.id, p2.name from public.prospects p2
        where pp.id is null and p2.user_id = r.user_id
          and public.crm_norm(p2.name) = public.crm_norm(coalesce(nullif(dd.company, ''), nullif(dd.client_name, ''), dd.contact))
        order by p2.date_updated desc limit 1
      ) pn on true
      where dd.user_id = r.user_id
        and ((abs(dd.ttc - r.amount) <= 0.05
              and not exists (select 1 from public.bank_receipts b
                              where b.document_num = dd.num and b.status = 'rapproche' and b.id <> p_id and abs(b.amount - r.amount) <= 0.05))
             or (dd.type = 'DEV' and dd.statut in ('Envoyé','Accepté')
                 and public.crm_quote_part(r.user_id, dd.num, dd.ttc, dd.doc_meta, r.amount, p_id) is not null))
        and dd.created_at::date <= r.date + 7 and dd.created_at::date >= r.date - 400
        and ((dd.type = 'DEV' and dd.statut in ('Envoyé','Accepté','Facturé')) or (dd.type <> 'DEV' and dd.statut <> 'Annulée'))
    ) x
    order by coalesce(x.prospect_id::text, public.crm_norm(x.client)), x.issued desc, (x.type <> 'DEV') desc, x.created_at desc
  ) q;

  v_n := jsonb_array_length(v_cands);
  select count(*) into v_n_named from jsonb_array_elements(v_cands) e where (e ->> 'named')::boolean;
  v_first := v_cands -> 0;
  v_part := v_first ->> 'part';

  if v_n_named = 1 then
    v_status := 'rapproche'; v_kind := 'montant_nom';
    v_note := case v_part when 'acompte' then 'Acompte du devis ' || (v_first ->> 'num') || ', nom du payeur reconnu'
                          when 'solde' then 'Solde du devis ' || (v_first ->> 'num') || ', nom du payeur reconnu'
                          else 'Montant identique et nom du payeur reconnu' end;
  elsif v_n = 1 then
    v_status := 'propose'; v_kind := 'montant';
    v_note := case v_part when 'acompte' then 'Montant de l''acompte du devis ' || (v_first ->> 'num') || ', nom du payeur non reconnu : à confirmer'
                          when 'solde' then 'Montant du solde du devis ' || (v_first ->> 'num') || ', nom du payeur non reconnu : à confirmer'
                          else 'Montant identique, nom du payeur non reconnu : à confirmer' end;
  elsif v_n > 1 then
    v_status := 'propose'; v_kind := 'montant'; v_note := v_n || ' clients ont un document de ce montant : à choisir';
  end if;

  if v_status is not null then
    update public.bank_receipts set payer = v_payer, status = v_status, match_kind = v_kind, match_note = v_note || v_reflabel,
      prospect_id = nullif(v_first ->> 'prospect_id', '')::uuid, document_num = v_first ->> 'num', document_type = v_first ->> 'type',
      candidates = v_cands, updated_at = now() where id = p_id;
    if v_status = 'rapproche' and p_mode <> 'aucun' then perform public.crm_apply_receipt(p_id, p_mode); end if;
    return v_status;
  end if;

  v_prospect := v_alias;
  if v_prospect is null then
    select p.id into v_prospect from public.prospects p
      where p.user_id = r.user_id and public.crm_client_matches(p.name, p.contact, r.label, v_payer)
      order by (p.statut = 'Gagné') desc, p.date_updated desc limit 1;
  end if;
  if v_prospect is null then
    select pp.id into v_prospect from public.documents dd join public.prospects pp on pp.id = dd.prospect_id
      where dd.user_id = r.user_id
        and (public.crm_client_matches(dd.company, dd.contact_name, r.label, v_payer) or public.crm_client_matches(dd.client_name, null, r.label, v_payer))
      order by dd.created_at desc limit 1;
  end if;
  if v_prospect is not null then
    select dd.* into d from public.documents dd
      where dd.user_id = r.user_id and dd.prospect_id = v_prospect and dd.type = 'DEV' and dd.statut in ('Envoyé','Accepté')
        and dd.ttc > 0 and dd.created_at::date <= r.date + 7
        and abs(r.amount / dd.ttc * 100 - round(r.amount / dd.ttc * 100, -1)) <= 0.5
        and round(r.amount / dd.ttc * 100, -1) between 10 and 90
      order by dd.created_at desc limit 1;
    if d.id is null then
      select dd.* into d from public.documents dd
        where dd.user_id = r.user_id and dd.prospect_id = v_prospect and dd.type = 'DEV' and dd.statut in ('Envoyé','Accepté')
          and dd.ttc > 0 and dd.created_at::date <= r.date + 7 and abs(r.amount - dd.ttc) / dd.ttc <= 0.08
        order by abs(r.amount - dd.ttc) limit 1;
      v_near := d.id is not null;
    end if;
    update public.bank_receipts set payer = v_payer, status = 'propose', match_kind = 'nom',
      match_note = case when d.id is not null and v_near
          then 'Payeur reconnu, montant proche du devis ' || d.num || ' (' || public.crm_money_fr(d.ttc) || ') : à confirmer'
        when d.id is not null
          then 'Payeur reconnu, acompte de ' || round(r.amount / d.ttc * 100, -1)::int || ' % sur le devis ' || d.num || ' : à confirmer'
          else 'Payeur reconnu, aucun document du même montant' end || v_reflabel,
      prospect_id = v_prospect, document_num = d.num, document_type = d.type, candidates = '[]'::jsonb, updated_at = now() where id = p_id;
    return 'propose';
  end if;

  update public.bank_receipts set payer = v_payer, status = 'nouveau', match_kind = null,
    match_note = 'Aucun client reconnu' || v_reflabel,
    prospect_id = null, document_num = null, document_type = null, candidates = '[]'::jsonb, updated_at = now() where id = p_id;
  return 'nouveau';
end $$;
