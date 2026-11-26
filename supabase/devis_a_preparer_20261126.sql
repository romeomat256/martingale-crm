-- Martingale CRM : « Devis à préparer » (26/11/2026, appliqué).
-- Après un appel, le CRM (IA ou règles) peut marquer la fiche « devis à préparer » :
--   devis_demande_at : date de la demande ; devis_brief : ce qu'il faut pour chiffrer (modèles, quantités, département, remise, délai...).
-- Dès qu'un devis est créé pour la fiche, la base retire la marque et passe la fiche en « Devis envoyé ».

alter table public.prospects
  add column if not exists devis_demande_at timestamptz,
  add column if not exists devis_brief jsonb;

create or replace function public.crm_quote_progress()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  begin
    if new.type = 'DEV' and new.prospect_id is not null
       and coalesce(new.statut, 'Envoyé') not in ('Doublon', 'Remplacé', 'Refusé') then
      if auth.uid() is null then perform set_config('crm.actor', 'Automatique (devis créé)', true); end if;
      update public.prospects p set
          statut = case when coalesce(p.statut, 'Nouveau') in ('Nouveau', 'Contacté') then 'Devis envoyé' else p.statut end,
          devis_demande_at = null,
          date_updated = now()
       where p.id = new.prospect_id
         and (coalesce(p.statut, 'Nouveau') in ('Nouveau', 'Contacté') or p.devis_demande_at is not null);
    end if;
  exception when others then
    raise warning 'crm_quote_progress : %', sqlerrm;
  end;
  return null;
end $$;

-- Mise à jour du 26/11/2026 (appliquée) : un devis créé fait passer la fiche « Devis envoyé » même si elle était
-- en attente ou perdue, et compte comme une activité du jour. Un client gagné reste gagné.
-- Essai en base (annulé) : Nouveau, En attente, Perdu et Devis envoyé endormi → Devis envoyé ; Gagné → Gagné.
create or replace function public.crm_quote_progress()
returns trigger language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  begin
    if new.type = 'DEV' and new.prospect_id is not null
       and coalesce(new.statut, 'Envoyé') not in ('Doublon', 'Remplacé', 'Refusé') then
      if auth.uid() is null then perform set_config('crm.actor', 'Automatique (devis créé)', true); end if;
      update public.prospects p set
          statut = case when coalesce(p.statut, 'Nouveau') = 'Gagné' then p.statut else 'Devis envoyé' end,
          devis_demande_at = null,
          date_updated = now()
       where p.id = new.prospect_id;
    end if;
  exception when others then
    raise warning 'crm_quote_progress : %', sqlerrm;
  end;
  return null;
end $$;
