// Martingale : commandes du site Shopify vers le CRM.
// Webhook Shopify « Création de commande » et « Paiement de commande ».
// Chaque commande crée ou met à jour : la fiche client (prospects) et une commande (orders).
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
  if (!/^orders\/(create|paid|updated)$/.test(topic)) return json(200, { ok: true, ignored: topic });

  let order: Record<string, any>;
  try { order = JSON.parse(raw); } catch { return json(400, { ok: false, error: "payload" }); }
  if (!order?.id) return json(400, { ok: false, error: "payload" });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const key = `shopify:${order.id}`;
  const paid = ["paid", "partially_refunded"].includes(String(order.financial_status || ""));
  const statut = order.cancelled_at ? "Annulé" : paid ? "Payé" : "Confirmé";

  // Commande déjà connue : on met seulement le statut à jour
  const { data: known } = await sb.from("orders").select("id, statut").eq("user_id", USER_ID).eq("devis_id", key).maybeSingle();
  if (known) {
    if (known.statut !== statut) await sb.from("orders").update({ statut }).eq("id", known.id);
    return json(200, { ok: true, mode: "status", statut });
  }
  if (topic === "orders/updated") return json(200, { ok: true, ignored: "unknown order" });

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
  if (email) {
    const { data: ex } = await sb.from("prospects").select("id, notes, tel, contact, name")
      .eq("user_id", USER_ID).ilike("email", email).limit(1).maybeSingle();
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
        email,
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
  return json(200, { ok: true, mode: "created", statut });
});
