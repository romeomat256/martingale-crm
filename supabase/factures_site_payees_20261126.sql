-- Une facture faite pour une commande du site (Shopify, payée par carte) est déjà payée.
-- Rapprochement : même client (nom contenu dans l'autre, ou même fiche), même montant TTC à 5 centimes près,
-- commande passée avant la facture. Une commande ne règle qu'une seule facture (la plus ancienne).
-- Seul le statut change (« Payée ») : une facture émise reste figée. Le journal garde la commande rapprochée.

create or replace function public.crm_site_invoices_settle()
returns integer language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; n integer := 0; v_used text[] := '{}'; v_actor text := current_setting('crm.actor', true);
begin
  -- Commandes déjà prises par une facture payée sur le site (lues dans le journal).
  select coalesce(array_agg(distinct substring(a.actor_name from '#[0-9]+')), '{}') into v_used
    from public.crm_activity a where a.table_name = 'documents' and a.actor_name like 'Payée sur le site%';
  for r in
    select d.id, d.num, o.quote_num
      from public.documents d
      join lateral (
        select o.quote_num from public.orders o
         where o.user_id = d.user_id and o.operation_category = 'shopify' and o.statut = 'Payé'
           and abs(coalesce(o.total_ttc, 0) - coalesce(d.ttc, 0)) <= 0.05
           and o.created_at <= d.invoice_issued_at + interval '1 day'
           and not (o.quote_num = any(v_used))
           and ((d.prospect_id is not null and o.prospect_id = d.prospect_id)
             or exists (select 1 from unnest(array[public.crm_doc_client_key(o.contact, null, null), public.crm_doc_client_key(o.client_name, null, null)]) ok(k),
                                    unnest(array[public.crm_doc_client_key(d.company, null, null), public.crm_doc_client_key(d.client_name, null, null), public.crm_doc_client_key(d.contact, null, null)]) dk(k)
                         where length(ok.k) >= 5 and length(dk.k) >= 5 and (dk.k like '%' || ok.k || '%' or ok.k like '%' || dk.k || '%')))
         order by o.created_at desc limit 1) o on true
     where d.type in ('FAC', 'FDF', 'SOL') and d.invoice_issued_at is not null
       and coalesce(d.statut, '') not in ('Payée', 'Annulée', 'Remplacé', 'Doublon')
     order by d.invoice_issued_at
  loop
    if r.quote_num = any(v_used) then continue; end if;
    perform set_config('crm.actor', 'Payée sur le site (commande ' || r.quote_num || ')', true);
    update public.documents set statut = 'Payée' where id = r.id;
    v_used := v_used || r.quote_num;
    n := n + 1;
  end loop;
  perform set_config('crm.actor', coalesce(v_actor, ''), true);
  return n;
end $$;
revoke all on function public.crm_site_invoices_settle() from public, anon, authenticated;

create or replace function public.crm_site_invoices_settle_trg()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_table_name = 'documents' then
    if new.invoice_issued_at is null or new.type not in ('FAC', 'FDF', 'SOL') then return null; end if;
  elsif new.operation_category is distinct from 'shopify' or new.statut is distinct from 'Payé' then
    return null;
  end if;
  perform public.crm_site_invoices_settle();
  return null;
end $$;

drop trigger if exists crm_site_invoices_settle on public.documents;
create trigger crm_site_invoices_settle after insert or update of invoice_issued_at on public.documents
  for each row execute function public.crm_site_invoices_settle_trg();
drop trigger if exists crm_site_invoices_settle on public.orders;
create trigger crm_site_invoices_settle after insert or update of statut on public.orders
  for each row execute function public.crm_site_invoices_settle_trg();

select public.crm_site_invoices_settle();
