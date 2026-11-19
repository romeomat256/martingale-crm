-- Échanges clients (Gmail, WhatsApp) rattachés aux fiches. Ajouts uniquement, rien n'est supprimé.
-- Appliqué en production le 19/11/2026 (migration messages_echanges_clients).
alter table public.messages
  add column if not exists direction text,
  add column if not exists external_id text,
  add column if not exists thread_id text,
  add column if not exists from_addr text,
  add column if not exists to_addr text,
  add column if not exists sent_at timestamptz,
  add column if not exists attachments jsonb not null default '[]'::jsonb,
  add column if not exists meta jsonb not null default '{}'::jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_direction_check') then
    alter table public.messages add constraint messages_direction_check check (direction is null or direction in ('in','out'));
  end if;
end $$;

-- Anti-doublon : un même message d'un même canal n'est enregistré qu'une fois.
create unique index if not exists messages_canal_external_idx on public.messages (canal, external_id);
create index if not exists messages_prospect_sent_idx on public.messages (prospect_id, sent_at desc);
