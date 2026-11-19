-- Une facture émise reste figée, mais son lien Pennylane (identifiant, date d'envoi, paiement)
-- n'est pas du contenu fiscal : il doit pouvoir être enregistré. Sans cela, le CRM ne savait
-- pas quelles factures étaient déjà dans Pennylane et affichait « 0 poussée ».
-- Appliqué en production le 19/11/2026 (migration facture_emise_lien_pennylane).
-- La fonction protect_crm_invoice compare désormais la facture avant / après en ignorant
-- trois colonnes : statut, updated_at et pennylane. Tout le reste demeure interdit, comme la suppression.
do $$
declare def text;
begin
  select pg_get_functiondef('public.protect_crm_invoice()'::regprocedure) into def;
  if position('- ''pennylane''' in def) > 0 then return; end if;
  if (length(def) - length(replace(def, '- ''statut'' - ''updated_at''', ''))) / length('- ''statut'' - ''updated_at''') <> 2 then
    raise exception 'protect_crm_invoice : structure inattendue, fonction laissée intacte.';
  end if;
  def := replace(def, '- ''statut'' - ''updated_at''', '- ''statut'' - ''updated_at'' - ''pennylane''');
  execute def;
end $$;
