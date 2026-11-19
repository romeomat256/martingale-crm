-- Rapprochement bancaire : les encaissements lus dans Pennylane sont rattachés aux devis,
-- factures et fiches du CRM.
-- Version complète, en production le 19/11/2026 (migrations crm_rapprochement_bancaire_tables,
-- crm_rapprochement_bancaire_fonctions et crm_rapprochement_reconnaissance_payeur).

-- ══════════════════════════════════════════════════════════════
-- 1. TABLES
-- ══════════════════════════════════════════════════════════════
create table if not exists public.bank_receipts (
  id bigint primary key,                 -- identifiant de la transaction dans Pennylane
  user_id uuid not null,                 -- propriétaire des données (équipe)
  date date not null,
  amount numeric not null,
  currency text not null default 'EUR',
  label text not null default '',
  payer text,                            -- nom du payeur lu dans le libellé
  status text not null default 'nouveau' check (status in ('nouveau','rapproche','propose','ignore')),
  match_kind text,                       -- reference | montant_nom | montant | nom | manuel | site
  match_note text,
  prospect_id uuid,
  document_num text,
  document_type text,
  candidates jsonb not null default '[]'::jsonb,
  applied boolean not null default false,
  pennylane_matched_at timestamptz,
  pennylane_note text,
  source text not null default 'api',     -- api (lecture automatique) | reprise (historique chargé le 19/11/2026)
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bank_receipts_status_idx on public.bank_receipts (user_id, status, date desc);
create index if not exists bank_receipts_prospect_idx on public.bank_receipts (prospect_id);
alter table public.bank_receipts enable row level security;
drop policy if exists team_read on public.bank_receipts;
create policy team_read on public.bank_receipts for select to authenticated
  using (user_id = coalesce((select public.crm_owner_id()), (select auth.uid())));

-- Chaque encaissement rattaché à une commande y apparaît comme un paiement.
alter table public.payments add column if not exists bank_receipt_id bigint;
create unique index if not exists payments_bank_receipt_idx on public.payments (bank_receipt_id) where bank_receipt_id is not null;

-- Payeurs déjà reconnus : « ALL FOR YOU » paie pour la fiche « Sous les Pins », etc.
create table if not exists public.bank_payer_aliases (
  payer_key text not null,
  user_id uuid not null,
  prospect_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, payer_key)
);
alter table public.bank_payer_aliases enable row level security;

-- ══════════════════════════════════════════════════════════════
-- 2. OUTILS DE LECTURE DU LIBELLÉ
-- ══════════════════════════════════════════════════════════════
create or replace function public.crm_norm(t text) returns text
language sql immutable set search_path to 'pg_catalog', 'public'
as $$
  select btrim(regexp_replace(translate(lower(coalesce(t, '')),
    'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ''’', 'aaaaaaceeeeiiiinooooouuuuyyoa  '), '[^a-z0-9]+', ' ', 'g'))
$$;

-- Numéros de devis ou de facture cités dans un libellé, remis au format du CRM.
create or replace function public.crm_extract_refs(p_label text) returns text[]
language plpgsql immutable set search_path to 'pg_catalog', 'public'
as $$
declare m text[]; refs text[] := '{}'; pfx text; u text := upper(coalesce(p_label, ''));
begin
  -- « DEV 260709 005 », « DEV260921 029 », « DEVIS 260522-182 », « DEV261005034 », « FAC 260522 007 »
  for m in select regexp_matches(u, '(DEVIS|DEV|FACTURE|FAC|FDF|SOL)[ ]{0,3}[-:#]?[ ]{0,3}([0-9]{6})[ ]{0,2}-?[ ]{0,2}([0-9]{1,3})(?![0-9])', 'g') loop
    pfx := case m[1] when 'DEVIS' then 'DEV' when 'FACTURE' then 'FAC' else m[1] end;
    refs := refs || (pfx || '-' || m[2] || '-' || lpad(m[3], 3, '0'));
  end loop;
  -- « FACT-000031 », « FACTURE 000031 »
  for m in select regexp_matches(u, 'FACT(?:URE)?[ ]{0,3}(?:N[O°]?)?[ ]{0,2}[-:#]?[ ]{0,2}([0-9]{6})(?![0-9])', 'g') loop
    refs := refs || ('FACT-' || m[1]);
  end loop;
  return (select coalesce(array_agg(distinct x), '{}') from unnest(refs) x);
end $$;

-- Nom du payeur : première ligne utile du libellé, sans « VIR SEPA », « VIR INST », etc.
create or replace function public.crm_payer(p_label text) returns text
language plpgsql immutable set search_path to 'pg_catalog', 'public'
as $$
declare lines text[] := regexp_split_to_array(coalesce(p_label, ''), E'\n'); l text;
begin
  l := btrim(regexp_replace(coalesce(lines[1], ''), '^VIR(EMENT)?[[:space:]]+(SEPA|INSTANTANE|INST|RECU)[[:space:]]*', '', 'i'));
  if l = '' or l ~ '^[0-9 ]+$' then l := btrim(coalesce(lines[2], '')); end if;
  l := btrim(split_part(l, ' - ', 1));
  return nullif(left(l, 120), '');
end $$;

-- Un des noms donnés se retrouve-t-il dans le libellé ? (mots de 4 lettres et plus, hors mots courants)
create or replace function public.crm_name_in_label(p_names text[], p_label text) returns boolean
language sql immutable set search_path to 'pg_catalog', 'public'
as $$
  select exists (
    select 1
    from unnest(p_names) n,
         regexp_split_to_table(public.crm_norm(n), ' ') w
    where length(w) >= 4
      and w not in ('sarl','sasu','eurl','hotel','restaurant','bistrot','cafe','brasserie','groupe','group','societe',
                    'studio','maison','paris','france','gmail','hotmail','orange','wanadoo','yahoo','free','client','clients',
                    'saint','sainte','villa','plage','beach','club','house','food','table','comptoir','petit','petite',
                    'grand','grande','chez','jean','pierre','marie','paul','martingale','surface','virement','inst','sepa')
      and (' ' || public.crm_norm(p_label) || ' ') like ('% ' || w || ' %')
  )
$$;

-- Le payeur d'un virement correspond-il à ce client ? (nom de la fiche ou du document, contact)
create or replace function public.crm_client_matches(p_name text, p_contact text, p_label text, p_payer text) returns boolean
language sql immutable set search_path to 'pg_catalog', 'public'
as $$
  select coalesce(
    -- un mot distinctif du nom figure dans le libellé
    (p_name is not null and position('@' in p_name) = 0 and public.crm_name_in_label(array[p_name], p_label))
    -- le nom est exactement celui du payeur (noms courts : « L'M »)
    or (public.crm_norm(p_name) <> '' and public.crm_norm(p_name) = public.crm_norm(p_payer))
    -- le nom de la fiche contient celui du payeur (« Sous les Pins (All For You) »)
    or (length(public.crm_norm(p_payer)) >= 6 and (' ' || public.crm_norm(p_name) || ' ') like ('% ' || public.crm_norm(p_payer) || ' %'))
    -- nom écrit en un seul mot d'un côté (« Portavia » / « PORTA VIA »)
    or (position('@' in coalesce(p_name, '')) = 0 and length(replace(public.crm_norm(p_name), ' ', '')) >= 6
        and replace(public.crm_norm(p_label), ' ', '') like ('%' || replace(public.crm_norm(p_name), ' ', '') || '%'))
    -- prénom et nom du contact tous présents dans le libellé
    or (array_length(regexp_split_to_array(nullif(public.crm_norm(p_contact), ''), ' '), 1) >= 2
        and not exists (select 1 from regexp_split_to_table(public.crm_norm(p_contact), ' ') w
                        where (' ' || public.crm_norm(p_label) || ' ') not like ('% ' || w || ' %')))
  , false)
$$;

create or replace function public.crm_money_fr(a numeric) returns text
language sql immutable set search_path to 'pg_catalog', 'public'
as $$ select replace(replace(to_char(a, 'FM999,999,990.00'), ',', ' '), '.', ',') || ' €' $$;

-- ══════════════════════════════════════════════════════════════
-- 3. EFFETS D'UN ENCAISSEMENT RAPPROCHÉ
-- Mode « complet » : devis accepté, commande créée, paiement sur la commande, facture payée,
-- fiche gagnée, paiement daté dans l'historique de la fiche.
-- Mode « historique » (reprise du passé) : paiement sur la commande existante et facture payée, rien d'autre.
-- ══════════════════════════════════════════════════════════════
create or replace function public.crm_apply_receipt(p_id bigint, p_mode text default 'complet') returns void
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare
  r public.bank_receipts%rowtype;
  d public.documents%rowtype;
  v_full boolean := p_mode = 'complet';
  v_quote text;
  v_order uuid;
  v_note text;
  v_paid numeric;
begin
  select * into r from public.bank_receipts where id = p_id for update;
  if not found or r.status <> 'rapproche' or r.applied then return; end if;
  if auth.uid() is null then perform set_config('crm.actor', 'Rapprochement bancaire', true); end if;

  if r.document_num is not null then
    select * into d from public.documents
      where user_id = r.user_id and num = r.document_num
      order by (invoice_issued_at is not null) desc, created_at desc limit 1;
  end if;

  if d.id is not null then
    v_quote := case when d.type = 'DEV' then d.num else nullif(d.invoice_snapshot ->> 'sourceQuoteNum', '') end;

    if d.type = 'DEV' and v_full then
      if d.statut = 'Envoyé' then
        update public.documents set statut = 'Accepté' where id = d.id;
      end if;
      -- La commande naît avec la vente, comme quand le devis est accepté à la main.
      if d.statut in ('Envoyé','Accepté') and not exists (select 1 from public.orders o where o.user_id = r.user_id and o.quote_num = d.num) then
        insert into public.orders (user_id, quote_num, devis_id, prospect_id, contact, prod_name, prod_id, qty, total_ttc, total_ht, tva, statut,
          client_name, company, contact_name, email, tel, billing_address, shipping_address, delivery_dept, validity, line_items,
          subtotal_brut_ht, subtotal_ht, global_discount_pct, global_discount_amount_ht, shipping_ht, shipping_mode,
          shipping_manual_ht, shipping_auto_ht, shipping_details, is_international, vat_regime, vat_rate, customer_vat_number,
          vat_legal_mention, operation_category)
        values (r.user_id, d.num, d.id::text, coalesce(r.prospect_id, d.prospect_id), d.contact, d.prod_name, d.prod_id, d.qty, d.ttc, d.ht, d.tva, 'Confirmé',
          d.client_name, d.company, d.contact_name, d.email, d.tel, d.billing_address, d.shipping_address, d.delivery_dept, d.validity, d.line_items,
          d.subtotal_brut_ht, d.subtotal_ht, d.global_discount_pct, d.global_discount_amount_ht, d.shipping_ht, d.shipping_mode,
          d.shipping_manual_ht, d.shipping_auto_ht, d.shipping_details, d.is_international, d.vat_regime, d.vat_rate, d.customer_vat_number,
          d.vat_legal_mention, d.operation_category);
      end if;
    elsif d.type <> 'DEV' and d.statut not in ('Payée','Annulée') then
      -- Facture : payée quand les encaissements rattachés couvrent son montant.
      select coalesce(sum(b.amount), 0) into v_paid from public.bank_receipts b
        where b.user_id = r.user_id and b.document_num = d.num and b.status = 'rapproche';
      if v_paid >= d.ttc - 0.05 then
        update public.documents set statut = 'Payée' where id = d.id;
      end if;
    end if;

    -- Le paiement s'inscrit sur la commande du devis.
    if v_quote is not null then
      select o.id into v_order from public.orders o where o.user_id = r.user_id and o.quote_num = v_quote order by o.created_at limit 1;
      if v_order is not null then
        insert into public.payments (user_id, order_id, montant, mode, date_paiement, statut, bank_receipt_id)
        values (r.user_id, v_order, r.amount, 'Virement', r.date, 'Reçu', r.id)
        on conflict do nothing;
      end if;
    end if;
  end if;

  if r.prospect_id is not null and v_full then
    v_note := '--- ' || to_char(r.date, 'YYYY-MM-DD') || ' 12:00 · Paiement reçu' || E'\n'
           || 'Virement ' || coalesce(r.payer, '') || ' de ' || public.crm_money_fr(r.amount)
           || case when r.document_num is not null then ' (' || case when coalesce(r.document_type, 'DEV') = 'DEV' then 'devis ' else 'facture ' end || r.document_num || ')' else '' end || '.';
    update public.prospects p set
      statut = 'Gagné',
      notes = case
        when position(public.crm_money_fr(r.amount) in coalesce(p.notes, '')) > 0 and position('Paiement reçu' in coalesce(p.notes, '')) > 0 then p.notes
        when coalesce(p.notes, '') = '' then v_note
        else p.notes || E'\n\n' || v_note end,
      date_updated = now()
    where p.id = r.prospect_id and p.user_id = r.user_id;
  end if;

  update public.bank_receipts set applied = true, updated_at = now() where id = p_id;
end $$;

-- ══════════════════════════════════════════════════════════════
-- 4. RAPPROCHEMENT D'UN ENCAISSEMENT
-- Ordre : numéro de devis ou de facture dans le libellé, puis montant identique et nom du payeur,
-- puis montant seul ou payeur seul (proposé, jamais confirmé tout seul).
-- p_mode : 'complet' (effets appliqués), 'historique' (effets limités), 'aucun' (simple lecture).
-- ══════════════════════════════════════════════════════════════
create or replace function public.crm_match_receipt(p_id bigint, p_mode text default 'complet') returns text
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
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
begin
  select * into r from public.bank_receipts where id = p_id for update;
  if not found then return 'introuvable'; end if;
  if r.decided_at is not null or r.applied then return r.status; end if;

  v_payer := public.crm_payer(r.label);
  v_refs := public.crm_extract_refs(r.label);
  v_reflabel := case when array_length(v_refs, 1) > 0 then ' (libellé : ' || array_to_string(v_refs, ', ') || ')' else '' end;

  -- Versements groupés du site : sans nom de client, ils ne se rattachent à aucune fiche.
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

  -- 1. Le libellé cite un devis ou une facture du CRM.
  if array_length(v_refs, 1) > 0 then
    select * into d from public.documents
      where user_id = r.user_id and num = any(v_refs)
      order by (invoice_issued_at is not null) desc, abs(ttc - r.amount), created_at desc limit 1;
  end if;

  if d.id is not null then
    -- Devis cité, facture émise du même montant : c'est la facture qui est réglée.
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
    v_note := case
      when abs(r.amount - d.ttc) <= 0.05 then 'Numéro cité dans le libellé, montant identique'
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

  -- 2. Même montant qu'un devis ou une facture encore ouverts (un seul document retenu par client).
  select coalesce(jsonb_agg(to_jsonb(q) order by q.named desc, q.created_at desc), '[]'::jsonb) into v_cands
  from (
    select distinct on (coalesce(x.prospect_id::text, public.crm_norm(x.client)))
           x.num, x.type, x.ttc, x.prospect_id, x.client, x.named, x.created_at
    from (
      select dd.num, dd.type, dd.ttc, dd.created_at, (dd.invoice_issued_at is not null) as issued,
             coalesce(pp.id, pn.id) as prospect_id,
             coalesce(nullif(dd.company, ''), nullif(dd.client_name, ''), dd.contact) as client,
             (public.crm_client_matches(coalesce(pp.name, pn.name), pp.contact, r.label, v_payer) or public.crm_client_matches(dd.company, dd.contact_name, r.label, v_payer) or public.crm_client_matches(dd.client_name, null, r.label, v_payer)
               or (v_alias is not null and v_alias = coalesce(pp.id, pn.id))) as named
      from public.documents dd
      left join public.prospects pp on pp.id = dd.prospect_id
      left join lateral (
        select p2.id, p2.name from public.prospects p2
        where pp.id is null and p2.user_id = r.user_id
          and public.crm_norm(p2.name) = public.crm_norm(coalesce(nullif(dd.company, ''), nullif(dd.client_name, ''), dd.contact))
        order by p2.date_updated desc limit 1
      ) pn on true
      where dd.user_id = r.user_id
        and abs(dd.ttc - r.amount) <= 0.05
        and dd.created_at::date <= r.date + 7 and dd.created_at::date >= r.date - 400
        and ((dd.type = 'DEV' and dd.statut in ('Envoyé','Accepté','Facturé')) or (dd.type <> 'DEV' and dd.statut <> 'Annulée'))
        and not exists (select 1 from public.bank_receipts b
                        where b.document_num = dd.num and b.status = 'rapproche' and b.id <> p_id and abs(b.amount - r.amount) <= 0.05)
    ) x
    order by coalesce(x.prospect_id::text, public.crm_norm(x.client)), x.issued desc, (x.type <> 'DEV') desc, x.created_at desc
  ) q;

  v_n := jsonb_array_length(v_cands);
  select count(*) into v_n_named from jsonb_array_elements(v_cands) e where (e ->> 'named')::boolean;
  v_first := v_cands -> 0;

  if v_n_named = 1 then
    v_status := 'rapproche'; v_kind := 'montant_nom'; v_note := 'Montant identique et nom du payeur reconnu';
  elsif v_n = 1 then
    v_status := 'propose'; v_kind := 'montant'; v_note := 'Montant identique, nom du payeur non reconnu : à confirmer';
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

  -- 3. Aucun document du même montant : le payeur est-il un client connu ?
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
    -- Un acompte rond (10 à 90 %) sur un devis ouvert de ce client ?
    select dd.* into d from public.documents dd
      where dd.user_id = r.user_id and dd.prospect_id = v_prospect and dd.type = 'DEV' and dd.statut in ('Envoyé','Accepté')
        and dd.ttc > 0 and dd.created_at::date <= r.date + 7
        and abs(r.amount / dd.ttc * 100 - round(r.amount / dd.ttc * 100, -1)) <= 0.5
        and round(r.amount / dd.ttc * 100, -1) between 10 and 90
      order by dd.created_at desc limit 1;
    -- Montant proche d'un devis ouvert (devis en devise étrangère, frais bancaires).
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

-- ══════════════════════════════════════════════════════════════
-- 5. DÉCISION DEPUIS LE CRM : confirmer, rattacher à un autre client, ignorer
-- ══════════════════════════════════════════════════════════════
create or replace function public.crm_decide_receipt(p_id bigint, p_action text, p_prospect uuid default null, p_document text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid := public.crm_owner_id();
  r public.bank_receipts%rowtype;
  d public.documents%rowtype;
  v_prospect uuid;
begin
  if v_me is null or v_owner is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  select * into r from public.bank_receipts where id = p_id and user_id = v_owner for update;
  if not found then raise exception 'Encaissement introuvable.'; end if;

  -- Détacher : l'encaissement redevient « à traiter ». Le paiement inscrit sur la commande est retiré ;
  -- les statuts déjà changés (devis, facture, fiche) restent à corriger à la main.
  if p_action = 'detacher' then
    delete from public.payments where bank_receipt_id = p_id and user_id = v_owner;
    update public.bank_receipts set status = 'nouveau', match_kind = null, match_note = 'Détaché à la main',
      prospect_id = null, document_num = null, document_type = null, candidates = '[]'::jsonb, applied = false,
      decided_by = v_me, decided_at = now(), updated_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'nouveau');
  end if;
  if r.applied then raise exception 'Cet encaissement est déjà rattaché. Le détacher d''abord.'; end if;

  if p_action = 'ignorer' then
    update public.bank_receipts set status = 'ignore', match_kind = 'manuel', match_note = 'Ignoré à la main',
      decided_by = v_me, decided_at = now(), updated_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'ignore');
  elsif p_action <> 'confirmer' then
    raise exception 'Action inconnue.';
  end if;

  if p_document is not null then
    select * into d from public.documents where user_id = v_owner and num = p_document
      order by (invoice_issued_at is not null) desc, created_at desc limit 1;
    if d.id is null then raise exception 'Document % introuvable.', p_document; end if;
  elsif p_prospect is null and r.document_num is not null then
    select * into d from public.documents where user_id = v_owner and num = r.document_num
      order by (invoice_issued_at is not null) desc, created_at desc limit 1;
  end if;

  v_prospect := coalesce(p_prospect, case when p_document is not null then d.prospect_id end, r.prospect_id, d.prospect_id);
  if v_prospect is null then raise exception 'Choisir le client de cet encaissement.'; end if;
  if not exists (select 1 from public.prospects where id = v_prospect and user_id = v_owner) then raise exception 'Fiche client introuvable.'; end if;

  update public.bank_receipts set status = 'rapproche',
    match_kind = case when p_prospect is not null or p_document is not null then 'manuel' else coalesce(match_kind, 'manuel') end,
    match_note = coalesce(match_note, '') || case when coalesce(match_note, '') = '' then '' else ' · ' end || 'Confirmé à la main',
    prospect_id = v_prospect, document_num = d.num, document_type = d.type,
    decided_by = v_me, decided_at = now(), updated_at = now() where id = p_id;

  -- Le CRM retient ce payeur pour la prochaine fois.
  if public.crm_norm(r.payer) <> '' then
    insert into public.bank_payer_aliases (payer_key, user_id, prospect_id)
    values (public.crm_norm(r.payer), v_owner, v_prospect)
    on conflict (user_id, payer_key) do update set prospect_id = excluded.prospect_id;
  end if;

  perform public.crm_apply_receipt(p_id, 'complet');
  return jsonb_build_object('ok', true, 'status', 'rapproche', 'prospect_id', v_prospect, 'document_num', d.num);
end $$;

revoke all on function public.crm_apply_receipt(bigint, text) from public, anon, authenticated;
revoke all on function public.crm_match_receipt(bigint, text) from public, anon, authenticated;
revoke all on function public.crm_decide_receipt(bigint, text, uuid, text) from public, anon;
grant execute on function public.crm_apply_receipt(bigint, text) to service_role;
grant execute on function public.crm_match_receipt(bigint, text) to service_role;
grant execute on function public.crm_decide_receipt(bigint, text, uuid, text) to authenticated;

revoke all on function public.crm_client_matches(text, text, text, text) from public, anon;
