-- Martingale CRM : automatisations du 19/11/2026
--   1. Fiche : champs société (SIREN, raison sociale, adresse, TVA)
--   2. Liens clients : date de première consultation d'un devis
--   3. Devis créé pour une fiche : la fiche passe seule en « Devis envoyé »
--   4. Commande pro expédiée : le stock baisse dans Shopify (file d'attente + fonction serveur shopify-stock)
--   5. État de synchronisation : ligne « stock vers Shopify »

-- ── 1. Fiche : société ──────────────────────────────────────────────────────
alter table public.prospects
  add column if not exists siren text,
  add column if not exists siret text,
  add column if not exists raison_sociale text,
  add column if not exists adresse text,
  add column if not exists code_postal text,
  add column if not exists tva_intra text;

-- ── 2. Liens clients ────────────────────────────────────────────────────────
alter table public.document_links add column if not exists first_viewed_at timestamptz;
update public.document_links set first_viewed_at = last_viewed_at
 where first_viewed_at is null and last_viewed_at is not null;

-- ── 3. Devis créé : fiche en « Devis envoyé » ───────────────────────────────
create or replace function public.crm_quote_progress()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  begin
    if new.type = 'DEV' and new.prospect_id is not null
       and coalesce(new.statut, 'Envoyé') not in ('Doublon', 'Remplacé', 'Refusé') then
      if auth.uid() is null then perform set_config('crm.actor', 'Automatique (devis créé)', true); end if;
      update public.prospects p set statut = 'Devis envoyé', date_updated = now()
       where p.id = new.prospect_id and coalesce(p.statut, 'Nouveau') in ('Nouveau', 'Contacté');
    end if;
  exception when others then
    raise warning 'crm_quote_progress : %', sqlerrm;
  end;
  return null;
end $$;

drop trigger if exists crm_quote_progress on public.documents;
create trigger crm_quote_progress after insert on public.documents
  for each row execute function public.crm_quote_progress();

-- ── 4. Stock : commande pro expédiée -> Shopify ─────────────────────────────
create table if not exists public.shopify_stock_moves (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  order_id uuid not null,
  quote_num text,
  client text,
  direction smallint not null check (direction in (-1, 1)),   -- -1 : sortie de stock, +1 : retour
  lines jsonb not null default '[]'::jsonb,                    -- [{product_id, qty, label, inventory_item_id, location_id}]
  unknown jsonb not null default '[]'::jsonb,                  -- lignes sans article Shopify (sur-mesure, autre produit)
  status text not null default 'a_faire' check (status in ('a_faire', 'fait', 'erreur', 'ignore')),
  note text,
  idem_key uuid not null default gen_random_uuid(),            -- le même mouvement ne s'applique qu'une fois côté Shopify
  tries integer not null default 0,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists shopify_stock_moves_order_idx on public.shopify_stock_moves (order_id, id);
create index if not exists shopify_stock_moves_todo_idx on public.shopify_stock_moves (id) where status = 'a_faire';
alter table public.shopify_stock_moves enable row level security;
drop policy if exists team_read on public.shopify_stock_moves;
create policy team_read on public.shopify_stock_moves for select
  using (user_id = coalesce((select public.crm_owner_id()), (select auth.uid())));

-- Chaises d'une commande, article par article, avec leur référence Shopify quand elle existe.
create or replace function public.crm_order_stock_lines(o public.orders)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$
declare v jsonb; v_pid text; v_n integer;
begin
  with l as (
    select nullif(e ->> 'prodId', '') as pid,
           case when (e ->> 'qty') ~ '^\d+(\.\d+)?$' then round((e ->> 'qty')::numeric)::int else 0 end as qty,
           coalesce(e ->> 'productName', e ->> 'name', '') as label
      from jsonb_array_elements(case when jsonb_typeof(o.line_items) = 'array' then o.line_items else '[]'::jsonb end) e
  ), g as (
    select pid, sum(qty)::int as qty, max(label) as label from l where pid is not null and qty > 0 group by pid
  )
  select jsonb_agg(jsonb_build_object('product_id', g.pid, 'qty', g.qty, 'label', g.label,
           'inventory_item_id', m.inventory_item_id, 'location_id', m.location_id) order by g.pid)
    into v
    from g left join public.shopify_inventory_map m on m.product_id = g.pid;
  if v is not null then return v; end if;

  -- Ancienne commande sans lignes : le produit est déduit de l'intitulé, s'il n'y en a qu'un seul possible.
  if coalesce(o.qty, 0) > 0 then
    v_pid := nullif(o.prod_id, '');
    if v_pid is null then
      select count(*), min(p.product_id) into v_n, v_pid from public.products p
       where p.user_id = o.user_id and length(public.crm_norm(p.name)) >= 4
         and position(public.crm_norm(p.name) in public.crm_norm(coalesce(o.prod_name, ''))) > 0;
      if v_n <> 1 then v_pid := null; end if;
    end if;
    if v_pid is not null then
      select jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', o.qty, 'label', coalesce(o.prod_name, ''),
               'inventory_item_id', m.inventory_item_id, 'location_id', m.location_id))
        into v
        from (select 1) x left join public.shopify_inventory_map m on m.product_id = v_pid;
      return v;
    end if;
  end if;
  return '[]'::jsonb;
end $$;
revoke execute on function public.crm_order_stock_lines(public.orders) from public, anon, authenticated;

-- Demande à la fonction serveur d'envoyer les mouvements en attente (appel différé, après validation de la transaction).
create or replace function public.crm_run_stock_push()
returns bigint language sql security definer set search_path to 'pg_catalog', 'public' as $$
  select net.http_post(
    url := 'https://hduxtygzhesmclxanocj.supabase.co/functions/v1/shopify-stock',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-crm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'crm_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000)
$$;
revoke execute on function public.crm_run_stock_push() from public, anon, authenticated;

-- Une commande pro passe en « Expédié » ou « Livré » : ses chaises sortent du stock Shopify, une seule fois.
-- Elle revient en arrière : le mouvement est annulé s'il n'est pas parti, sinon les chaises sont remises.
-- Les commandes du site ne sont pas concernées : Shopify a déjà compté la vente.
create or replace function public.crm_order_stock_move()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare
  v_new boolean; v_old boolean;
  v_last public.shopify_stock_moves%rowtype;
  v_lines jsonb; v_known jsonb; v_unknown jsonb;
  v_status text := 'a_faire'; v_note text;
  v_queued boolean := false;
begin
  begin
    if coalesce(new.operation_category, '') = 'shopify' then return null; end if;
    v_new := new.statut in ('Expédié', 'Livré');
    v_old := tg_op = 'UPDATE' and old.statut in ('Expédié', 'Livré');
    if v_new = v_old then return null; end if;

    select * into v_last from public.shopify_stock_moves
     where order_id = new.id and not (status = 'ignore' and direction = -1 and note like 'Annulé :%')
     order by id desc limit 1;

    if v_new then
      if v_last.id is not null and v_last.direction = -1 then return null; end if;   -- déjà sorti
      v_lines := public.crm_order_stock_lines(new);
      select coalesce(jsonb_agg(e) filter (where (e ->> 'inventory_item_id') is not null), '[]'::jsonb),
             coalesce(jsonb_agg(e) filter (where (e ->> 'inventory_item_id') is null), '[]'::jsonb)
        into v_known, v_unknown
        from jsonb_array_elements(v_lines) e;
      if jsonb_array_length(v_known) = 0 then
        v_status := 'ignore'; v_note := 'Aucune chaise du stock reconnue dans cette commande.';
      elsif new.created_at < timestamptz '2026-11-19 00:00+01' then
        v_status := 'ignore'; v_note := 'Commande antérieure au branchement : stock Shopify non modifié.';
      end if;
      insert into public.shopify_stock_moves (user_id, order_id, quote_num, client, direction, lines, unknown, status, note)
      values (new.user_id, new.id, new.quote_num, coalesce(new.company, new.client_name, new.contact), -1, v_known, v_unknown, v_status, v_note);
      v_queued := v_status = 'a_faire';
    else
      if v_last.id is null or v_last.direction = 1 then return null; end if;
      if v_last.status = 'fait' then
        insert into public.shopify_stock_moves (user_id, order_id, quote_num, client, direction, lines, status, note)
        values (new.user_id, new.id, new.quote_num, v_last.client, 1, v_last.lines, 'a_faire',
                'Retour : commande repassée en « ' || coalesce(new.statut, '') || ' ».');
        v_queued := true;
      else
        update public.shopify_stock_moves
           set status = 'ignore', note = 'Annulé : commande repassée en « ' || coalesce(new.statut, '') || ' » avant l''envoi à Shopify.'
         where id = v_last.id;
      end if;
    end if;

    if v_queued then perform public.crm_run_stock_push(); end if;
  exception when others then
    raise warning 'crm_order_stock_move : %', sqlerrm;
  end;
  return null;
end $$;

drop trigger if exists crm_order_stock_move on public.orders;
create trigger crm_order_stock_move after insert or update of statut on public.orders
  for each row execute function public.crm_order_stock_move();

-- Depuis le CRM : relancer un mouvement en erreur, ou appliquer un mouvement laissé de côté.
create or replace function public.crm_stock_move_retry(p_id bigint)
returns void language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
declare v_owner uuid := public.crm_owner_id();
begin
  if v_owner is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  update public.shopify_stock_moves set status = 'a_faire', tries = 0, note = null
   where id = p_id and user_id = v_owner and status in ('ignore', 'erreur') and jsonb_array_length(lines) > 0
     and coalesce(note, '') not like 'Annulé :%';
  if found then perform public.crm_run_stock_push(); end if;
end $$;
revoke execute on function public.crm_stock_move_retry(bigint) from public, anon;
grant execute on function public.crm_stock_move_retry(bigint) to authenticated;

-- Reprise : tous les quarts d'heure, seulement s'il reste un mouvement à envoyer.
select cron.unschedule('crm-stock-shopify') where exists (select 1 from cron.job where jobname = 'crm-stock-shopify');
select cron.schedule('crm-stock-shopify', '*/15 * * * *',
  $cron$select public.crm_run_stock_push() where exists (select 1 from public.shopify_stock_moves where status = 'a_faire')$cron$);

-- ── 5. État de synchronisation : stock vers Shopify ─────────────────────────
do $patch$
declare
  v_def text;
  v_old text := E'    ''tache_horaire'',';
  v_new text;
begin
  select pg_get_functiondef('public.crm_sync_status()'::regprocedure) into v_def;
  if position('stock_shopify' in v_def) > 0 then return; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'crm_sync_status : repère introuvable';
  end if;
  v_new := E'    ''stock_shopify'', jsonb_build_object(\n'
        || E'      ''etat'', (select s.value || jsonb_build_object(''passage'', s.updated_at) from public.crm_sync_state s where s.key = ''shopify_push''),\n'
        || E'      ''a_faire'', (select count(*) from public.shopify_stock_moves m where m.user_id = v_owner and m.status = ''a_faire''),\n'
        || E'      ''erreurs'', (select count(*) from public.shopify_stock_moves m where m.user_id = v_owner and m.status = ''erreur''),\n'
        || E'      ''laisses'', (select count(*) from public.shopify_stock_moves m where m.user_id = v_owner and m.status = ''ignore'' and m.note like ''Shopify pas encore branché%''),\n'
        || E'      ''dernier'', (select max(m.done_at) from public.shopify_stock_moves m where m.user_id = v_owner and m.status = ''fait'' and m.direction = -1)),\n';
  execute replace(v_def, v_old, v_new || v_old);
end $patch$;

-- ── 6. Reprise : les fiches qui ont déjà un devis quittent « Nouveau » et « Contacté » ──
do $$
begin
  perform set_config('crm.actor', 'Automatique (devis créé)', true);
  update public.prospects p set statut = 'Devis envoyé', date_updated = now()
   where coalesce(p.statut, 'Nouveau') in ('Nouveau', 'Contacté')
     and exists (select 1 from public.documents d where d.prospect_id = p.id and d.type = 'DEV'
                  and d.statut not in ('Doublon', 'Remplacé', 'Refusé'));
end $$;
