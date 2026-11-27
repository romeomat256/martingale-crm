-- Stock : correction à la chaise depuis le CRM (boutons − / +, arrivée saisie).
-- Le niveau du CRM bouge tout de suite, et le même mouvement part vers Shopify
-- par la file shopify_stock_moves (même circuit que les commandes expédiées).
create or replace function public.crm_stock_adjust(p_product text, p_delta integer, p_reason text default null)
returns integer language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_owner uuid := public.crm_owner_id();
  v_cur integer; v_delta integer; v_new integer;
  v_map public.shopify_inventory_map%rowtype;
begin
  if v_owner is null then raise exception 'Connexion requise'; end if;
  if coalesce(p_product, '') = '' then raise exception 'Modèle manquant'; end if;
  if abs(coalesce(p_delta, 0)) > 5000 then raise exception 'Quantité trop grande'; end if;
  select rolls into v_cur from public.stock where product_id = p_product;
  v_cur := coalesce(v_cur, 0);
  v_delta := greatest(coalesce(p_delta, 0), -v_cur);   -- jamais sous zéro
  if v_delta = 0 then return v_cur; end if;

  insert into public.stock (user_id, product_id, rolls, updated_at)
  values (v_owner, p_product, v_cur + v_delta, now())
  on conflict (product_id) do update set rolls = excluded.rolls, updated_at = now()
  returning rolls into v_new;

  select * into v_map from public.shopify_inventory_map where product_id = p_product;
  if v_map.inventory_item_id is not null then
    insert into public.shopify_stock_moves (user_id, quote_num, direction, lines, status, note)
    values (v_owner, 'Correction CRM', sign(v_delta)::smallint,
            jsonb_build_array(jsonb_build_object('product_id', p_product, 'qty', abs(v_delta), 'label', p_product,
              'inventory_item_id', v_map.inventory_item_id, 'location_id', v_map.location_id)),
            'a_faire', coalesce(nullif(p_reason, ''), 'Correction du stock depuis le CRM'));
    perform public.crm_run_stock_push();
  end if;
  return v_new;
end $$;
revoke all on function public.crm_stock_adjust(text, integer, text) from public, anon;
grant execute on function public.crm_stock_adjust(text, integer, text) to authenticated;
