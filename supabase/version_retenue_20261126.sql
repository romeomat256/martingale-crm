-- Le client paie (ou accepte) une version : les autres versions du même client sortent seules.
-- « Même client » : même fiche, ou fiche au même nom (fiches en double), ou même société sans fiche.
-- « Version » : devis encore « Envoyé », non facturé, fait à 45 jours ou moins du devis retenu.
-- Ils passent en « Remplacé » avec remplacePar = le devis retenu. « Restaurer » les remet en cours.

create or replace function public.crm_doc_client_key_of(p_doc public.documents)
returns text language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(
    (select public.crm_doc_client_key(p.name, null, null) from public.prospects p where p.id = p_doc.prospect_id),
    public.crm_doc_client_key(p_doc.company, p_doc.client_name, p_doc.contact))
$$;

create or replace function public.crm_quote_versions_close(p_won public.documents)
returns integer language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_key text; n integer;
begin
  v_key := public.crm_doc_client_key_of(p_won);
  if p_won.prospect_id is null and v_key is null then return 0; end if;
  update public.documents o
     set statut = 'Remplacé',
         doc_meta = coalesce(o.doc_meta, '{}'::jsonb)
                    || jsonb_build_object('remplacePar', p_won.num, 'remplaceLe', now(), 'motif', 'version retenue')
   where o.user_id = p_won.user_id
     and o.type = 'DEV' and o.statut = 'Envoyé' and o.id <> p_won.id
     and o.invoice_issued_at is null
     and abs(extract(epoch from (o.created_at - p_won.created_at))) <= 45 * 86400
     and (o.prospect_id = p_won.prospect_id
          or (v_key is not null and public.crm_doc_client_key_of(o) = v_key));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.crm_quote_versions_close(public.documents) from public, anon, authenticated;

create or replace function public.crm_quote_won()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.type = 'DEV' and new.statut in ('Accepté', 'Facturé')
     and old.statut is distinct from new.statut and old.statut not in ('Accepté', 'Facturé') then
    perform public.crm_quote_versions_close(new);
  end if;
  return null;
end $$;

drop trigger if exists crm_quote_won on public.documents;
create trigger crm_quote_won after update of statut on public.documents
  for each row execute function public.crm_quote_won();

-- Un nouveau devis range aussi les versions posées sur une fiche en double (même nom).
create or replace function public.crm_quote_supersede()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_key text;
begin
  if new.type <> 'DEV' or coalesce(new.statut, 'Envoyé') <> 'Envoyé' then return null; end if;
  v_key := public.crm_doc_client_key_of(new);
  if new.prospect_id is null and v_key is null then return null; end if;
  update public.documents o
     set statut = case when o.line_items is not distinct from new.line_items
                        and round(coalesce(o.ht, 0), 2) = round(coalesce(new.ht, 0), 2)
                       then 'Doublon' else 'Remplacé' end,
         doc_meta = coalesce(o.doc_meta, '{}'::jsonb)
                    || jsonb_build_object('remplacePar', new.num, 'remplaceLe', now())
   where o.user_id = new.user_id
     and o.type = 'DEV' and o.statut = 'Envoyé' and o.id <> new.id
     and o.invoice_issued_at is null
     and o.created_at < new.created_at
     and (o.prospect_id = new.prospect_id
          or (v_key is not null and public.crm_doc_client_key_of(o) = v_key));
  return null;
end $$;

-- Reprise : les devis déjà acceptés ou facturés rangent leurs versions.
select set_config('crm.actor', 'Version retenue', true);
select public.crm_quote_versions_close(d) from public.documents d
 where d.type = 'DEV' and d.statut in ('Accepté', 'Facturé');
