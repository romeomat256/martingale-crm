-- Équipe (plusieurs utilisateurs sur les mêmes données), responsable par fiche,
-- journal automatique des modifications.
-- Appliqué en production le 19/11/2026 (migration crm_equipe_et_journal).
-- Ajouts uniquement : aucune donnée existante n'est supprimée.

-- ══════════════════════════════════════════════════════════════
-- 1. MEMBRES DE L'ÉQUIPE
-- owner_id = le compte propriétaire des données (colonne user_id de toutes les tables).
-- ══════════════════════════════════════════════════════════════
create table if not exists public.crm_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  owner_id uuid not null references auth.users(id),
  display_name text not null,
  role text not null default 'admin' check (role in ('admin','membre')),
  created_at timestamptz not null default now()
);
alter table public.crm_members enable row level security;

insert into public.crm_members (user_id, owner_id, display_name, role)
values ('e0ea9ee1-90e8-4162-9e80-d264b7f993fb', 'e0ea9ee1-90e8-4162-9e80-d264b7f993fb', 'Roméo', 'admin')
on conflict (user_id) do nothing;

-- Le propriétaire des données pour le compte connecté (null si le compte n'est dans aucune équipe).
create or replace function public.crm_owner_id() returns uuid
language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$ select owner_id from public.crm_members where user_id = auth.uid() $$;
revoke all on function public.crm_owner_id() from public, anon;
grant execute on function public.crm_owner_id() to authenticated, service_role;

drop policy if exists team_read on public.crm_members;
create policy team_read on public.crm_members for select to authenticated
  using (owner_id = (select public.crm_owner_id()));

-- ══════════════════════════════════════════════════════════════
-- 2. ACCÈS PARTAGÉ : un membre voit et modifie les données du propriétaire.
-- Un compte hors équipe garde le comportement d'avant (ses propres lignes).
-- ══════════════════════════════════════════════════════════════
do $$
declare r record;
begin
  for r in select tablename, policyname from pg_policies
           where schemaname = 'public' and policyname in ('own_data','own_html','own_links')
  loop
    execute format(
      'alter policy %I on public.%I using (user_id = coalesce((select public.crm_owner_id()), (select auth.uid()))) with check (user_id = coalesce((select public.crm_owner_id()), (select auth.uid())))',
      r.policyname, r.tablename);
  end loop;
end $$;

-- Toute ligne créée par un membre est rangée chez le propriétaire.
create or replace function public.crm_set_owner() returns trigger
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_owner uuid := public.crm_owner_id();
begin
  if v_owner is not null then new.user_id := v_owner; end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['conteneurs','doc_counters','document_html','document_links','documents',
                           'invoice_drafts','messages','orders','payments','products','prospects','rdv','stock']
  loop
    execute format('drop trigger if exists crm_set_owner on public.%I', t);
    execute format('create trigger crm_set_owner before insert on public.%I for each row execute function public.crm_set_owner()', t);
  end loop;
end $$;

-- ══════════════════════════════════════════════════════════════
-- 3. RESPONSABLE PAR FICHE
-- ══════════════════════════════════════════════════════════════
alter table public.prospects add column if not exists responsable_id uuid references auth.users(id) on delete set null;
comment on column public.prospects.responsable_id is 'Membre de l''équipe qui suit ce client (null = non attribué)';

-- Les fiches existantes sont suivies par Roméo jusqu'à réattribution.
update public.prospects set responsable_id = 'e0ea9ee1-90e8-4162-9e80-d264b7f993fb'
where user_id = 'e0ea9ee1-90e8-4162-9e80-d264b7f993fb' and responsable_id is null;

-- Une fiche créée à la main par un membre lui est attribuée. Les fiches créées
-- automatiquement (Shopify, WhatsApp, configurateur) restent « non attribuées ».
create or replace function public.crm_prospect_defaults() returns trigger
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
begin
  if new.responsable_id is null and auth.uid() is not null
     and exists (select 1 from public.crm_members where user_id = auth.uid()) then
    new.responsable_id := auth.uid();
  end if;
  return new;
end $$;
drop trigger if exists crm_prospect_defaults on public.prospects;
create trigger crm_prospect_defaults before insert on public.prospects
  for each row execute function public.crm_prospect_defaults();

-- ══════════════════════════════════════════════════════════════
-- 4. JOURNAL DES MODIFICATIONS
-- Rempli par la base elle-même : rien à faire côté application, rien ne peut l'oublier.
-- ══════════════════════════════════════════════════════════════
create table if not exists public.crm_activity (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  owner_id uuid not null,
  actor_id uuid,
  actor_name text not null,
  table_name text not null,
  row_id text not null,
  prospect_id uuid,
  action text not null check (action in ('insert','update','delete')),
  label text,
  changes jsonb not null default '{}'::jsonb
);
create index if not exists crm_activity_owner_at_idx on public.crm_activity (owner_id, at desc);
create index if not exists crm_activity_prospect_at_idx on public.crm_activity (prospect_id, at desc);
alter table public.crm_activity enable row level security;
drop policy if exists team_read on public.crm_activity;
create policy team_read on public.crm_activity for select to authenticated
  using (owner_id = coalesce((select public.crm_owner_id()), (select auth.uid())));

-- Valeur lisible et courte pour le journal (les gros contenus ne sont pas recopiés).
create or replace function public.crm_audit_value(v jsonb) returns jsonb
language sql immutable set search_path to 'pg_catalog', 'public'
as $$
  select case
    when v is null or jsonb_typeof(v) = 'null' then 'null'::jsonb
    when jsonb_typeof(v) in ('object','array') then
      case when length(v::text) <= 200 then v else to_jsonb('(contenu modifié)'::text) end
    when jsonb_typeof(v) = 'string' and length(v #>> '{}') > 200 then to_jsonb(left(v #>> '{}', 200) || '…')
    else v
  end
$$;

create or replace function public.crm_log_activity() returns trigger
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare
  v_new jsonb; v_old jsonb; v_row jsonb;
  v_changes jsonb := '{}'::jsonb;
  k text;
  v_actor uuid; v_name text; v_owner uuid; v_prospect uuid;
begin
  -- Le journal ne doit jamais empêcher une écriture : toute erreur ici est ignorée.
  begin
    if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
    if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
    v_row := coalesce(v_new, v_old);
    if tg_op = 'UPDATE' then
      for k in select jsonb_object_keys(v_new) loop
        if k in ('id','user_id','date_updated','updated_at','created_at','date_created','html','invoice_snapshot','kb_order') then continue; end if;
        if (v_old -> k) is distinct from (v_new -> k) then
          v_changes := v_changes || jsonb_build_object(k,
            jsonb_build_array(public.crm_audit_value(v_old -> k), public.crm_audit_value(v_new -> k)));
        end if;
      end loop;
      if v_changes = '{}'::jsonb then return null; end if;
    end if;
    v_owner := nullif(v_row ->> 'user_id', '')::uuid;
    if v_owner is null then return null; end if;
    v_actor := auth.uid();
    if v_actor is not null then
      select display_name into v_name from public.crm_members where user_id = v_actor;
    end if;
    v_name := coalesce(v_name, nullif(current_setting('crm.actor', true), ''),
                       case when v_actor is null then 'Automatique' else 'Compte hors équipe' end);
    v_prospect := case when tg_table_name = 'prospects' then nullif(v_row ->> 'id', '')::uuid
                       else nullif(v_row ->> 'prospect_id', '')::uuid end;
    insert into public.crm_activity (owner_id, actor_id, actor_name, table_name, row_id, prospect_id, action, label, changes)
    values (v_owner, v_actor, v_name, tg_table_name, coalesce(v_row ->> 'id', ''), v_prospect, lower(tg_op),
            left(coalesce(v_row ->> 'name', v_row ->> 'num', v_row ->> 'quote_num', v_row ->> 'product_id',
                          v_row ->> 'reference', v_row ->> 'titre', v_row ->> 'client', ''), 200),
            v_changes);
  exception when others then
    raise warning 'crm_log_activity : %', sqlerrm;
  end;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['prospects','documents','orders','invoice_drafts','stock','products','payments','rdv','conteneurs']
  loop
    execute format('drop trigger if exists crm_log_activity on public.%I', t);
    execute format('create trigger crm_log_activity after insert or update or delete on public.%I for each row execute function public.crm_log_activity()', t);
  end loop;
end $$;

-- ══════════════════════════════════════════════════════════════
-- 5. GESTION DE L'ÉQUIPE (réservée aux administrateurs)
-- ══════════════════════════════════════════════════════════════
create or replace function public.crm_add_member(p_email text, p_name text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid; v_role text; v_target uuid;
  v_name text := btrim(coalesce(p_name, ''));
begin
  if v_me is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  select owner_id, role into v_owner, v_role from public.crm_members where user_id = v_me;
  if v_owner is null or v_role <> 'admin' then
    raise exception 'Réservé aux administrateurs de l''équipe.' using errcode = '42501';
  end if;
  if length(v_name) < 2 then raise exception 'Prénom requis.'; end if;
  select id into v_target from auth.users where lower(email) = lower(btrim(coalesce(p_email, ''))) limit 1;
  if v_target is null then
    raise exception 'Aucun compte avec cet e-mail. Crée d''abord le compte dans Supabase (Authentication, Users).';
  end if;
  if exists (select 1 from public.crm_members where user_id = v_target and owner_id <> v_owner) then
    raise exception 'Ce compte appartient déjà à une autre équipe.';
  end if;
  insert into public.crm_members (user_id, owner_id, display_name, role)
  values (v_target, v_owner, left(v_name, 60), 'admin')
  on conflict (user_id) do update set display_name = excluded.display_name;
  -- Mêmes droits que le propriétaire : émission des factures comprise.
  update public.crm_invoice_series set allowed_users = array_append(allowed_users, v_target)
  where v_owner = any(allowed_users) and not (v_target = any(allowed_users));
  return jsonb_build_object('ok', true, 'user_id', v_target, 'display_name', left(v_name, 60));
end $$;

create or replace function public.crm_remove_member(p_user uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_me uuid := auth.uid(); v_owner uuid; v_role text;
begin
  if v_me is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  select owner_id, role into v_owner, v_role from public.crm_members where user_id = v_me;
  if v_owner is null or v_role <> 'admin' then
    raise exception 'Réservé aux administrateurs de l''équipe.' using errcode = '42501';
  end if;
  if p_user = v_owner then raise exception 'Le propriétaire du CRM ne peut pas être retiré.'; end if;
  if not exists (select 1 from public.crm_members where user_id = p_user and owner_id = v_owner) then
    raise exception 'Ce compte ne fait pas partie de l''équipe.';
  end if;
  delete from public.crm_members where user_id = p_user and owner_id = v_owner;
  update public.crm_invoice_series set allowed_users = array_remove(allowed_users, p_user)
  where v_owner = any(allowed_users);
  -- Ses fiches reviennent au propriétaire.
  update public.prospects set responsable_id = v_owner where user_id = v_owner and responsable_id = p_user;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.crm_rename_member(p_user uuid, p_name text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_me uuid := auth.uid(); v_owner uuid; v_role text; v_name text := btrim(coalesce(p_name, ''));
begin
  if v_me is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  select owner_id, role into v_owner, v_role from public.crm_members where user_id = v_me;
  if v_owner is null or (v_role <> 'admin' and p_user <> v_me) then
    raise exception 'Réservé aux administrateurs de l''équipe.' using errcode = '42501';
  end if;
  if length(v_name) < 2 then raise exception 'Prénom requis.'; end if;
  update public.crm_members set display_name = left(v_name, 60) where user_id = p_user and owner_id = v_owner;
  if not found then raise exception 'Ce compte ne fait pas partie de l''équipe.'; end if;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.crm_add_member(text, text) from public, anon;
revoke all on function public.crm_remove_member(uuid) from public, anon;
revoke all on function public.crm_rename_member(uuid, text) from public, anon;
grant execute on function public.crm_add_member(text, text) to authenticated;
grant execute on function public.crm_remove_member(uuid) to authenticated;
grant execute on function public.crm_rename_member(uuid, text) to authenticated;

-- ══════════════════════════════════════════════════════════════
-- 6. FACTURATION : une facture émise par un membre est rangée chez le propriétaire,
-- et la reprise d'une émission interrompue la retrouve. Le reste de la fonction est inchangé.
-- ══════════════════════════════════════════════════════════════
do $$
declare def text; before_def text;
begin
  select pg_get_functiondef('public.issue_crm_invoice(uuid,jsonb,text)'::regprocedure) into def;
  if position('v_owner' in def) > 0 then return; end if; -- déjà fait
  before_def := def;
  def := replace(def, 'v_user uuid := auth.uid();',
                      'v_user uuid := auth.uid();' || E'\n  v_owner uuid := coalesce(public.crm_owner_id(), auth.uid());');
  def := replace(def, 'where user_id = v_user and invoice_request_id = p_request_id',
                      'where user_id = v_owner and invoice_request_id = p_request_id');
  def := replace(def, '''user_id'',v_user,', '''user_id'',v_owner,');
  if (length(def) - length(replace(def, 'v_owner', ''))) / length('v_owner') <> 3 then
    raise exception 'issue_crm_invoice : structure inattendue, fonction laissée intacte.';
  end if;
  execute def;
end $$;
