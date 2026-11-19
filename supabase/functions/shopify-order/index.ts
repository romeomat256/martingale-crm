// Martingale : boutique Shopify vers le CRM (commandes et stock).
// Webhooks Shopify : « Création de commande », « Paiement de commande », « Mise à jour de commande »,
// « Annulation de commande » et « Mise à jour du niveau de stock ».
// Chaque commande crée ou met à jour : la fiche client (prospects) et une commande (orders).
// Chaque mouvement de stock recopie le disponible Shopify dans la table stock.
// Sécurité : signature HMAC vérifiée avec SHOPIFY_WEBHOOK_SECRET (clé affichée par Shopify
// dans Paramètres > Notifications > Webhooks). verify_jwt = false : Shopify n'envoie pas de jeton.

import { createClient } from "jsr:@supabase/supabase-js@2";

const USER_ID = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const SOURCE = "Shopify - Commande";

// SKU Shopify -> identifiant produit du CRM
function prodIdFromSku(sku: string): string | null {
  const m = String(sku || "").toUpperCase().match(/^MART-BISTROT-(.+)$/);
  return m ? m[1].toLowerCase() : null;
}

const enc = new TextEncoder();

async function signatureOk(raw: string, header: string | null, secret: string): Promise<boolean> {
  if (!header) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(raw)));
  const expected = btoa(String.fromCharCode(...sig));
  if (expected.length !== header.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ header.charCodeAt(i);
  return diff === 0;
}

const r2 = (v: number) => Math.round((v + Number.EPSILON) * 100) / 100;
const num = (v: unknown) => Number(v) || 0;

function formatAddress(a: Record<string, any> | null | undefined): string {
  if (!a) return "";
  return [a.company, a.address1, a.address2, [a.zip, a.city].filter(Boolean).join(" "), a.country !== "France" ? a.country : ""]
    .filter((x) => x && String(x).trim()).join(", ");
}

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false });
  const secret = Deno.env.get("SHOPIFY_WEBHOOK_SECRET");
  if (!secret) return json(503, { ok: false, error: "not_configured" });

  const raw = await req.text();
  if (!(await signatureOk(raw, req.headers.get("x-shopify-hmac-sha256"), secret))) {
    return json(401, { ok: false, error: "signature" });
  }
  const topic = req.headers.get("x-shopify-topic") || "orders/create";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Stock : Shopify annonce le nouveau niveau disponible d'un article, le CRM le recopie.
  if (topic === "inventory_levels/update") {
    let lvl: Record<string, any>;
    try { lvl = JSON.parse(raw); } catch { return json(400, { ok: false, error: "payload" }); }
    const itemId = Number(lvl?.inventory_item_id);
    const available = Number(lvl?.available);
    if (!itemId || !Number.isFinite(available)) return json(200, { ok: true, ignored: "payload" });
    const { data: map } = await sb.from("shopify_inventory_map").select("product_id, location_id").eq("inventory_item_id", itemId).maybeSingle();
    if (!map) return json(200, { ok: true, ignored: "unknown item" });
    if (map.location_id && lvl.location_id && Number(map.location_id) !== Number(lvl.location_id)) return json(200, { ok: true, ignored: "other location" });
    const now = new Date().toISOString();
    const { error } = await sb.from("stock").upsert(
      { product_id: map.product_id, rolls: Math.max(0, Math.round(available)), user_id: USER_ID, source: "shopify", synced_at: now, updated_at: now },
      { onConflict: "product_id" },
    );
    if (error) { console.error("stock", error); return json(500, { ok: false, error: "stock" }); }
    await sb.from("crm_sync_state").upsert({ key: "shopify_stock", value: { at: now, product: map.product_id, available }, updated_at: now });
    return json(200, { ok: true, mode: "stock", product: map.product_id, available });
  }

  if (!/^orders\/(create|paid|updated|cancelled)$/.test(topic)) return json(200, { ok: true, ignored: topic });

  let order: Record<string, any>;
  try { order = JSON.parse(raw); } catch { return json(400, { ok: false, error: "payload" }); }
  if (!order?.id) return json(400, { ok: false, error: "payload" });

  const key = `shopify:${order.id}`;
  const financial = String(order.financial_status || "");
  const paid = ["paid", "partially_refunded"].includes(financial);
  const statut = (order.cancelled_at || financial === "refunded" || financial === "voided") ? "Annulé" : paid ? "Payé" : "Confirmé";

  // Commande déjà connue : on met seulement le statut à jour
  const { data: known } = await sb.from("orders").select("id, statut").eq("user_id", USER_ID).eq("devis_id", key).maybeSingle();
  if (known) {
    // Une annulation s'applique toujours ; « Confirmé » devient « Payé » ; un statut posé à la main (Expédié, Livré) est gardé.
    const next = statut === "Annulé" ? "Annulé" : (known.statut === "Confirmé" && statut === "Payé" ? "Payé" : known.statut);
    if (known.statut !== next) await sb.from("orders").update({ statut: next }).eq("id", known.id);
    return json(200, { ok: true, mode: "status", statut: next });
  }
  if (topic === "orders/updated" || topic === "orders/cancelled") return json(200, { ok: true, ignored: "unknown order" });

  // Lignes et montants (boutique en prix HT : taxes_included = false)
  const taxesIncluded = !!order.taxes_included;
  const ht = (v: number) => (taxesIncluded ? v / 1.2 : v);
  const lines = (order.line_items || []).map((li: Record<string, any>) => {
    const prodId = prodIdFromSku(li.sku);
    const qty = num(li.quantity);
    const unit = r2(ht(num(li.price)));
    const lineDiscount = r2(ht((li.discount_allocations || []).reduce((s: number, d: any) => s + num(d.amount), 0)));
    const total = r2(unit * qty - lineDiscount);
    return {
      prodId: prodId || "",
      productName: String(li.title || "").replace(/^Chaise bistrot en rotin /i, "Chaise Martingale "),
      productRef: li.sku || "",
      qty,
      unitPriceHT: unit,
      lineDiscountPct: unit * qty > 0 ? r2((lineDiscount / (unit * qty)) * 100) : 0,
      unitPriceNetHT: qty ? r2(total / qty) : unit,
      totalHT: total,
    };
  });
  const qty = lines.reduce((s: number, l: any) => s + l.qty, 0);
  const totalTTC = num(order.total_price);
  const tva = num(order.total_tax);
  const totalHT = r2(totalTTC - tva);
  const shippingHT = r2(ht((order.shipping_lines || []).reduce((s: number, l: any) => s + num(l.discounted_price ?? l.price), 0)));
  const subtotalHT = r2(lines.reduce((s: number, l: any) => s + l.totalHT, 0));

  const bill = order.billing_address || order.customer?.default_address || null;
  const ship = order.shipping_address || null;
  const email = String(order.email || order.customer?.email || "").trim().toLowerCase();
  const person = [order.customer?.first_name || bill?.first_name, order.customer?.last_name || bill?.last_name].filter(Boolean).join(" ").trim();
  const company = String(bill?.company || ship?.company || "").trim();
  const tel = String(order.phone || bill?.phone || ship?.phone || order.customer?.phone || "").trim();
  const zip = String(ship?.zip || bill?.zip || "");
  const summary = lines.map((l: any) => `${l.productName} x${l.qty}`).join(", ");

  // Fiche client
  let prospectId: string | null = null;
  const note = [
    `--- ${new Date().toISOString().slice(0, 16).replace("T", " ")} · Commande site ${order.name}`,
    summary,
    `Total : ${totalTTC.toFixed(2)} € TTC · ${paid ? "payée" : "en attente de paiement"}`,
    ship ? `Livraison : ${formatAddress(ship)}` : "",
  ].filter(Boolean).join("\n");
  // La fiche est retrouvée par e-mail, sinon par téléphone, sinon par nom de société. Elle est créée si elle n'existe pas.
  const tel9 = tel.replace(/\D/g, "").slice(-9);
  if (email || person || company) {
    let ex: any = null;
    if (email) {
      const { data } = await sb.from("prospects").select("id, notes, tel, contact, name")
        .eq("user_id", USER_ID).ilike("email", email).limit(1).maybeSingle();
      ex = data;
    }
    if (!ex && (tel9.length === 9 || company.length >= 5)) {
      const { data: all } = await sb.from("prospects").select("id, notes, tel, contact, name")
        .eq("user_id", USER_ID).order("date_created", { ascending: true }).limit(3000);
      const norm = (s: string) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
      ex = (tel9.length === 9 ? (all || []).find((p: any) => String(p.tel || "").replace(/\D/g, "").slice(-9) === tel9) : null)
        || (company.length >= 5 ? (all || []).find((p: any) => norm(p.name) === norm(company)) : null)
        || null;
    }
    if (ex) {
      prospectId = ex.id;
      await sb.from("prospects").update({
        statut: "Gagné",
        notes: ex.notes ? `${ex.notes}\n\n${note}` : note,
        tel: ex.tel || tel || null,
        contact: ex.contact || person || null,
        date_updated: new Date().toISOString(),
      }).eq("id", ex.id);
    } else {
      const { data: ins, error } = await sb.from("prospects").insert({
        user_id: USER_ID,
        name: company || person || email,
        contact: person || null,
        email: email || null,
        tel: tel || null,
        ville: ship?.city || bill?.city || null,
        dept: zip.slice(0, 2) || null,
        source: SOURCE,
        statut: "Gagné",
        qty,
        produits: lines.filter((l: any) => l.prodId).map((l: any) => ({ id: l.prodId, qty: l.qty })),
        score: 60,
        notes: note,
      }).select("id").single();
      if (error) { console.error("prospect", error); return json(500, { ok: false, error: "prospect" }); }
      prospectId = ins?.id || null;
    }
  }

  // Commande
  const { error } = await sb.from("orders").insert({
    user_id: USER_ID,
    devis_id: key,
    quote_num: order.name,
    prospect_id: prospectId,
    contact: company || person || email,
    client_name: person || company || email,
    company: company || null,
    contact_name: person || null,
    email: email || null,
    tel: tel || null,
    billing_address: formatAddress(bill) || null,
    shipping_address: formatAddress(ship) || null,
    delivery_dept: zip.slice(0, 2) || null,
    prod_name: summary,
    prod_id: lines[0]?.prodId || null,
    qty,
    line_items: lines,
    subtotal_brut_ht: subtotalHT,
    subtotal_ht: subtotalHT,
    global_discount_pct: 0,
    global_discount_amount_ht: r2(ht(num(order.total_discounts))),
    shipping_ht: shippingHT,
    shipping_mode: "shopify",
    total_ht: totalHT,
    tva,
    total_ttc: totalTTC,
    vat_rate: tva > 0 ? 0.2 : 0,
    vat_regime: "france",
    is_international: !!(ship && ship.country_code && ship.country_code !== "FR"),
    statut,
    operation_category: "shopify",
    created_at: order.created_at || new Date().toISOString(),
  });
  if (error) {
    // Deux notifications presque simultanées : la commande existe déjà
    if ((error as any).code === "23505") return json(200, { ok: true, mode: "duplicate" });
    console.error("order", error);
    return json(500, { ok: false, error: "order" });
  }

  // Tant que Shopify n'envoie pas les niveaux de stock en direct, la commande retire elle-même les chaises du stock du CRM.
  if (statut !== "Annulé") {
    const { data: live } = await sb.from("crm_sync_state").select("key").eq("key", "shopify_stock").maybeSingle();
    if (!live) {
      for (const l of lines) {
        if (!l.prodId || !l.qty) continue;
        const { data: st } = await sb.from("stock").select("rolls").eq("product_id", l.prodId).maybeSingle();
        if (!st) continue;
        await sb.from("stock").update({ rolls: Math.max(0, Math.round(num(st.rolls) - l.qty)), updated_at: new Date().toISOString() }).eq("product_id", l.prodId);
      }
    }
  }
  return json(200, { ok: true, mode: "created", statut });
});
