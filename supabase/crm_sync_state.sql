-- Mémoire des synchronisations automatiques (ex. dernier passage WhatsApp).
-- Appliqué en production le 19/11/2026 (migration crm_sync_state).
create table if not exists public.crm_sync_state (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.crm_sync_state enable row level security;
