-- Un nouveau devis pour la même fiche (ou, sans fiche, pour la même société) range les anciens.
-- Ancien devis différent : « Remplacé ». Ancien devis identique (mêmes lignes, même montant) : « Doublon ».
-- Seuls les devis encore « Envoyé » et non facturés sont touchés. Rien n'est supprimé :
-- le filtre « Archivés » et le bouton « Restaurer » les remettent en cours.

create or replace function public.crm_doc_client_key(p_company text, p_client text, p_contact text)
returns text language sql immutable set search_path = pg_catalog, public as $$
  select nullif(trim(regexp_replace(
    translate(lower(coalesce(nullif(trim(p_company), ''), nullif(trim(p_client), ''), nullif(trim(p_contact), ''), '')),
              'àâäáãéèêëíìîïóòôöõúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'),
    '[^a-z0-9]+', ' ', 'g')), '')
$$;

create or replace function public.crm_quote_supersede()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_key text;
begin
  if new.type <> 'DEV' or coalesce(new.statut, 'Envoyé') <> 'Envoyé' then return null; end if;
  v_key := public.crm_doc_client_key(new.company, new.client_name, new.contact);
  if new.prospect_id is null and v_key is null then return null; end if;

  update public.documents o
     set statut = case when o.line_items is not distinct from new.line_items
                        and round(coalesce(o.ht, 0), 2) = round(coalesce(new.ht, 0), 2)
                       then 'Doublon' else 'Remplacé' end,
         doc_meta = coalesce(o.doc_meta, '{}'::jsonb)
                    || jsonb_build_object('remplacePar', new.num, 'remplaceLe', now())
   where o.user_id = new.user_id
     and o.type = 'DEV'
     and o.statut = 'Envoyé'
     and o.id <> new.id
     and o.invoice_issued_at is null
     and o.created_at < new.created_at
     and (case when new.prospect_id is not null then o.prospect_id = new.prospect_id
               else o.prospect_id is null and public.crm_doc_client_key(o.company, o.client_name, o.contact) = v_key end);
  return null;
end $$;

drop trigger if exists crm_quote_supersede on public.documents;
create trigger crm_quote_supersede after insert on public.documents
  for each row execute function public.crm_quote_supersede();

-- Reprise : les devis « Envoyé » déjà doublés par un plus récent pour le même client.
select set_config('crm.actor', 'Remplacement automatique', true);
with g as (
  select d.id, d.num, d.ht, d.line_items, d.created_at,
         coalesce(d.prospect_id::text, 'n:' || public.crm_doc_client_key(d.company, d.client_name, d.contact)) as k
    from public.documents d
   where d.type = 'DEV' and d.statut = 'Envoyé' and d.invoice_issued_at is null
     and (d.prospect_id is not null or public.crm_doc_client_key(d.company, d.client_name, d.contact) is not null)
), last as (
  select distinct on (k) k, num, ht, line_items, created_at from g order by k, created_at desc
)
update public.documents o
   set statut = case when g.line_items is not distinct from l.line_items
                      and round(coalesce(g.ht, 0), 2) = round(coalesce(l.ht, 0), 2)
                     then 'Doublon' else 'Remplacé' end,
       doc_meta = coalesce(o.doc_meta, '{}'::jsonb) || jsonb_build_object('remplacePar', l.num, 'remplaceLe', now())
  from g join last l on l.k = g.k
 where o.id = g.id and g.created_at < l.created_at;
