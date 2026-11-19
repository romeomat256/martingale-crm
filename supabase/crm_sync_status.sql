-- État de toutes les synchronisations, pour la carte « Synchronisation » du CRM
-- (banque et factures Pennylane, Gmail, WhatsApp, demandes du site).
-- Appliqué en production le 19/11/2026 (migration crm_sync_status).
create or replace function public.crm_sync_status() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_owner uuid := public.crm_owner_id();
begin
  if v_owner is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'banque', (select coalesce(s.value, '{}'::jsonb) || jsonb_build_object('passage', s.updated_at)
               from public.crm_sync_state s where s.key = 'banque_passage'),
    'banque_a_traiter', (select count(*) from public.bank_receipts b where b.user_id = v_owner and b.status in ('propose','nouveau')),
    'factures', jsonb_build_object(
      'envoyees', (select count(*) from public.documents d where d.user_id = v_owner and d.invoice_issued_at is not null and d.pennylane is not null),
      'en_attente', (select count(*) from public.documents d where d.user_id = v_owner and d.invoice_issued_at is not null and d.pennylane is null
                     and d.invoice_issued_at > now() - interval '90 days')),
    'gmail', jsonb_build_object(
      'dernier', (select max(m.created_at) from public.messages m where m.user_id = v_owner and m.canal = 'gmail'),
      'sur_7_jours', (select count(*) from public.messages m where m.user_id = v_owner and m.canal = 'gmail' and m.created_at > now() - interval '7 days')),
    'whatsapp', jsonb_build_object(
      'passage', (select s.updated_at from public.crm_sync_state s where s.key = 'whatsapp_passage'),
      'dernier', (select max(m.created_at) from public.messages m where m.user_id = v_owner and m.canal = 'whatsapp')),
    'site', jsonb_build_object(
      'derniere_demande', (select max(p.date_created) from public.prospects p where p.user_id = v_owner and p.source ilike 'Shopify%')),
    'tache_horaire', exists (select 1 from cron.job j where j.jobname = 'crm-rapprochement-bancaire' and j.active)
  );
end $$;
revoke all on function public.crm_sync_status() from public, anon;
grant execute on function public.crm_sync_status() to authenticated;
