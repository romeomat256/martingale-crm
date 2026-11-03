-- Catalogue extensible (nov. 2026) : à exécuter une fois dans l'éditeur SQL Supabase (projet CRM martingale).
-- Le CRM lit la table `products` au démarrage : les chaises codées en dur gardent leur fiche,
-- mais leur prix peut être corrigé ici ; les autres lignes (tables, piétements, plateaux…) s'ajoutent au catalogue.

alter table public.products add column if not exists categorie text not null default 'chaise';   -- chaise | table | pietement | plateau | autre
alter table public.products add column if not exists description text;                           -- une ligne, affichée sous le nom dans le devis
create unique index if not exists products_user_product_idx on public.products(user_id, product_id);

-- L'ancien placeholder « Chaise personnalisée » (Chair 11) est remplacé par les lignes sur-mesure (205 € HT) créées dans le devis.
update public.products set actif = false where product_id = 'nouveau-modele';
