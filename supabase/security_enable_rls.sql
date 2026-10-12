-- Sécurité de la base CRM (appliqué le 12/10/2026, migration security_enable_rls_crm)
-- Les formulaires du site et du configurateur écrivent via les fonctions serveur
-- quote-request et lead-configurateur (clé service), non concernées par ces règles.

-- 1. Données regroupées sur le compte CRM principal (trace dans rls_reassign_backup)
create table if not exists public.rls_reassign_backup(table_name text, row_id text, old_user_id uuid, moved_at timestamptz default now());
alter table public.rls_reassign_backup enable row level security;
insert into public.rls_reassign_backup(table_name,row_id,old_user_id)
  select 'prospects', id::text, user_id from public.prospects where user_id='68f4de25-d6e0-45ba-a3b8-951b89c36f32'
  union all
  select 'documents', id::text, user_id from public.documents where user_id='68f4de25-d6e0-45ba-a3b8-951b89c36f32';
update public.prospects set user_id='e0ea9ee1-90e8-4162-9e80-d264b7f993fb' where user_id='68f4de25-d6e0-45ba-a3b8-951b89c36f32';
update public.documents set user_id='e0ea9ee1-90e8-4162-9e80-d264b7f993fb' where user_id='68f4de25-d6e0-45ba-a3b8-951b89c36f32';

-- 2. Sécurité par ligne : chaque compte connecté ne voit que ses données
alter table public.prospects    enable row level security;
alter table public.documents    enable row level security;
alter table public.orders       enable row level security;
alter table public.stock        enable row level security;
alter table public.conteneurs   enable row level security;
alter table public.doc_counters enable row level security;

-- 3. Politiques réservées aux comptes connectés
alter policy own_data on public.prospects    to authenticated;
alter policy own_data on public.documents    to authenticated;
alter policy own_data on public.orders       to authenticated;
alter policy own_data on public.stock        to authenticated;
alter policy own_data on public.conteneurs   to authenticated;
alter policy own_data on public.doc_counters to authenticated;
alter policy own_data on public.messages     to authenticated;
alter policy own_data on public.payments     to authenticated;
alter policy own_data on public.products     to authenticated;
alter policy own_data on public.rdv          to authenticated;

-- 4. Aucun accès pour un visiteur non connecté
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
revoke execute on function public.issue_crm_invoice(uuid, jsonb, text) from anon, public;
grant execute on function public.issue_crm_invoice(uuid, jsonb, text) to authenticated;

-- Retour arrière des réaffectations si besoin :
-- update public.prospects p set user_id=b.old_user_id from public.rls_reassign_backup b where b.table_name='prospects' and b.row_id=p.id::text;
-- update public.documents d set user_id=b.old_user_id from public.rls_reassign_backup b where b.table_name='documents' and b.row_id=d.id::text;
