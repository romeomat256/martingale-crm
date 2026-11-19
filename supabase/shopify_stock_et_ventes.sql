-- Lien Shopify : stock et ventes du site. Appliqué en production le 19/11/2026
-- (migration crm_shopify_stock_et_ventes, puis reprise des données).
--
-- Stock : la table stock recopie le « disponible » de Shopify (colonnes source = 'shopify', synced_at).
--   - shopify_inventory_map : article de stock Shopify -> produit du CRM (11 chaises, un seul lieu de stock).
--   - la fonction serveur shopify-order traite la notification « Mise à jour du niveau de stock ».
--   - tant que cette notification n'est pas branchée dans Shopify, chaque commande du site retire
--     elle-même ses chaises du stock du CRM.
-- Ventes : les commandes #1002 à #1049 ont été reprises dans orders (operation_category = 'shopify'),
--   à leur date, avec leurs lignes. #1001 (essai annulé) est laissée de côté. Les commandes remboursées
--   (#1009, #1029) et annulées (#1050) sont au statut « Annulé » et ne comptent pas dans le chiffre d'affaires.

create table if not exists public.shopify_inventory_map (
  inventory_item_id bigint primary key,
  sku text not null,
  product_id text not null,
  location_id bigint,
  created_at timestamptz not null default now()
);
alter table public.shopify_inventory_map enable row level security;
revoke all on public.shopify_inventory_map from anon, authenticated;

alter table public.stock add column if not exists source text;
alter table public.stock add column if not exists synced_at timestamptz;
-- crm_sync_status() : voir crm_sync_status.sql, avec en plus le bloc « boutique »
-- (stock_lu, stock_en_direct, derniere_commande, commandes).
