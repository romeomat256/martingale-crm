-- Rapprochement bancaire : passage automatique toutes les heures de 7 h à 21 h (heure de Paris en hiver),
-- CRM fermé et ordinateur éteint.
-- Appliqué en production le 19/11/2026 (migration crm_rapprochement_automatisation), fonction « pennylane-bank » déployée.
-- Le secret partagé entre la base et la fonction est créé ici et ne sort jamais de la base.

create extension if not exists pg_cron;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'crm_cron_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'crm_cron_secret',
                                'Secret des tâches programmées du CRM (rapprochement bancaire)');
  end if;
end $$;

-- La fonction serveur vérifie le secret reçu sans jamais le lire.
create or replace function public.crm_cron_secret_ok(p text) returns boolean
language sql stable security definer set search_path to 'pg_catalog', 'public'
as $$
  select coalesce(length(p) >= 32 and exists (
    select 1 from vault.decrypted_secrets s where s.name = 'crm_cron_secret' and s.decrypted_secret = p), false)
$$;
revoke all on function public.crm_cron_secret_ok(text) from public, anon, authenticated;
grant execute on function public.crm_cron_secret_ok(text) to service_role;

-- Lance un passage : appel de la fonction serveur, sans attendre sa réponse.
create or replace function public.crm_run_bank_sync() returns bigint
language sql security definer set search_path to 'pg_catalog', 'public'
as $$
  select net.http_post(
    url := 'https://hduxtygzhesmclxanocj.supabase.co/functions/v1/pennylane-bank',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-crm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'crm_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000)
$$;
revoke all on function public.crm_run_bank_sync() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'crm-rapprochement-bancaire';
select cron.schedule('crm-rapprochement-bancaire', '7 6-20 * * *', $$select public.crm_run_bank_sync()$$);
