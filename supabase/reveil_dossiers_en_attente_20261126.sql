-- Martingale CRM : réveil des dossiers « En attente » (26/11/2026, appliqué).
-- Déclencheur crm_message_progress, après chaque échange enregistré (mail ou WhatsApp) :
--   1. réponse envoyée à une nouvelle demande : la fiche passe « Contacté » (existant) ;
--   2. échange, reçu ou envoyé, sur un dossier « En attente chantier » plus récent que sa mise en attente :
--      la fiche repasse « Devis envoyé » si elle a un devis, sinon « Contacté ».
-- Essai en base (annulé) : avec devis → Devis envoyé ; sans devis → Contacté ; vieux mail repris → reste en attente.

create or replace function public.crm_message_progress()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $function$
declare
  v_at timestamptz := coalesce(new.sent_at, now());
begin
  begin
    if new.prospect_id is null then return null; end if;
    if new.direction = 'out' or (new.meta ->> 'repondu') = 'true' then
      if auth.uid() is null then
        perform set_config('crm.actor', case when new.canal = 'whatsapp' then 'Automatique (réponse WhatsApp)' else 'Automatique (e-mail envoyé)' end, true);
      end if;
      update public.prospects p set statut = 'Contacté', date_updated = now()
       where p.id = new.prospect_id and coalesce(p.statut, 'Nouveau') = 'Nouveau'
         and v_at >= p.date_created - interval '1 hour';
    end if;
    if exists (select 1 from public.prospects p
                where p.id = new.prospect_id and p.statut = 'En attente chantier'
                  and v_at > coalesce(p.date_updated, p.date_created)) then
      if auth.uid() is null then
        perform set_config('crm.actor', case when new.canal = 'whatsapp' then 'Automatique (WhatsApp)' else 'Automatique (e-mail)' end, true);
      end if;
      update public.prospects p set
          statut = case when exists (select 1 from public.documents d
                                      where d.prospect_id = p.id and d.type = 'DEV'
                                        and coalesce(d.statut, 'Envoyé') not in ('Doublon', 'Remplacé', 'Refusé'))
                        then 'Devis envoyé' else 'Contacté' end,
          date_updated = now()
       where p.id = new.prospect_id and p.statut = 'En attente chantier';
    end if;
  exception when others then
    raise warning 'crm_message_progress : %', sqlerrm;
  end;
  return null;
end $function$;
