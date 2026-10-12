-- Brouillons de facture : aucun numéro tant que la facture n'est pas émise.
-- Appliqué le 12/10/2026 (migration invoice_drafts). L'émission passe toujours par issue_crm_invoice.
create table if not exists public.invoice_drafts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  request_id uuid not null unique,
  type text not null check (type in ('FAC','FDF','SOL')),
  source_quote_num text,
  client text,
  ttc numeric,
  record jsonb not null,
  html text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.invoice_drafts enable row level security;
revoke all on public.invoice_drafts from anon;
create policy own_data on public.invoice_drafts for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update, delete on public.invoice_drafts to authenticated;
