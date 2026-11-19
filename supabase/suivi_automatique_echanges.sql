-- Suivi automatique des échanges. Appliqué en production le 19/11/2026 (migration crm_suivi_automatique_echanges).
-- 1. Dès qu'une réponse de Roméo ou de son équipe est enregistrée pour une fiche encore « Nouveau »
--    (e-mail envoyé, ou résumé WhatsApp avec meta.repondu = true), la fiche passe en « Contacté ».
-- 2. crm_exchange_state() : dernier message reçu et dernier message envoyé par fiche, pour les listes
--    « Réponses reçues » et « Sans réponse » du CRM.
create or replace function public.crm_message_progress() returns trigger
language plpgsql security definer set search_path to 'pg_catalog', 'public'
as $$
begin
  begin
    if new.prospect_id is null then return null; end if;
    if new.direction = 'out' or (new.meta ->> 'repondu') = 'true' then
      if auth.uid() is null then
        perform set_config('crm.actor', case when new.canal = 'whatsapp' then 'Automatique (réponse WhatsApp)' else 'Automatique (e-mail envoyé)' end, true);
      end if;
      -- Seulement si la réponse est postérieure à la demande : un vieux mail repris de l'historique ne compte pas.
      update public.prospects p set statut = 'Contacté', date_updated = now()
       where p.id = new.prospect_id and coalesce(p.statut, 'Nouveau') = 'Nouveau'
         and coalesce(new.sent_at, now()) >= p.date_created - interval '1 hour';
    end if;
  exception when others then
    raise warning 'crm_message_progress : %', sqlerrm;
  end;
  return null;
end $$;
revoke all on function public.crm_message_progress() from public, anon, authenticated;

drop trigger if exists crm_message_progress on public.messages;
create trigger crm_message_progress after insert on public.messages
  for each row execute function public.crm_message_progress();

create or replace function public.crm_exchange_state() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public'
as $$
declare v_owner uuid := public.crm_owner_id();
begin
  if v_owner is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('p', x.prospect_id, 'recu', x.last_in, 'envoye', x.last_out)), '[]'::jsonb)
    from (
      select m.prospect_id,
             max(coalesce(m.sent_at, m.created_at)) filter (where m.direction = 'in' or (m.meta ->> 'repondu') = 'false') as last_in,
             max(coalesce(m.sent_at, m.created_at)) filter (where m.direction = 'out' or (m.meta ->> 'repondu') = 'true') as last_out
      from public.messages m
      join public.prospects p on p.id = m.prospect_id and p.statut not in ('Gagné', 'Perdu')
      where m.user_id = v_owner
      group by m.prospect_id
    ) x
  );
end $$;
revoke all on function public.crm_exchange_state() from public, anon;
grant execute on function public.crm_exchange_state() to authenticated;
