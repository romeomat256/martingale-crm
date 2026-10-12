// Martingale : liaison CRM -> Pennylane.
// Actions (POST JSON, appelées par le CRM avec la session de Roméo) :
//   { action: "status" }                        -> la clé Pennylane est-elle configurée ?
//   { action: "push", num, pdf_base64 }         -> envoie une facture émise (PDF + montants) dans Pennylane
//   { action: "payments" }                      -> relit dans Pennylane les factures payées et les marque payées
// Clé : PENNYLANE_API_TOKEN (Pennylane > Paramètres > Connectivité > Développeurs, droits
// « customer_invoices », « customers », « file_attachments »).

import { createClient } from "jsr:@supabase/supabase-js@2";

const USER_ID = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const API = "https://app.pennylane.com/api/external/v2";
// Codes TVA Pennylane (à confirmer avec le comptable si besoin)
const VAT_FR = "FR_200";
const VAT_EU = Deno.env.get("PENNYLANE_VAT_EU") || "crossborder";
const VAT_EXPORT = Deno.env.get("PENNYLANE_VAT_EXPORT") || "extracom";

const ALLOWED_ORIGINS = ["https://martingale-crm.vercel.app"];
function cors(origin: string | null): Record<string, string> {
  const ok = origin && (ALLOWED_ORIGINS.includes(origin) || /^https:\/\/martingale-crm[a-z0-9-]*\.vercel\.app$/.test(origin) || /^http:\/\/localhost:\d+$/.test(origin));
  return {
    "Access-Control-Allow-Origin": ok ? origin! : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const money = (v: unknown) => (Math.round((Number(v) || 0) * 100) / 100).toFixed(2);

function isoFromFr(d: string): string {
  const m = String(d || "").match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : new Date().toISOString().slice(0, 10);
}

async function pl(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...(init.headers || {}) },
  });
  const text = await res.text();
  let body: any = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = { raw: text.slice(0, 500) }; }
  if (!res.ok) throw new Error(`Pennylane ${res.status} ${path} : ${JSON.stringify(body).slice(0, 400)}`);
  return body;
}

function customerKey(snap: Record<string, any>): string {
  if (snap.prospectId) return `prospect:${snap.prospectId}`;
  const n = String(snap.company || snap.clientName || snap.contact || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-");
  return `nom:${n || "client"}`;
}

function splitAddress(addr: string) {
  const s = String(addr || "").trim();
  const m = s.match(/^(.*?)[,\s]+(\d{4,5})\s+([^,]+?)(?:,\s*(.+))?$/);
  if (m) return { address: m[1].trim() || s, postal_code: m[2], city: m[3].trim(), country_alpha2: guessCountry(m[4] || "") };
  return { address: s || "-", postal_code: "-", city: "-", country_alpha2: guessCountry(s) };
}
function guessCountry(s: string): string {
  const t = s.toLowerCase();
  const map: [RegExp, string][] = [[/belgi/, "BE"], [/allemagne|germany|deutschland/, "DE"], [/suisse|switzerland|schweiz/, "CH"], [/espagne|spain/, "ES"], [/itali/, "IT"], [/royaume|united kingdom|\buk\b|london/, "GB"], [/usa|united states|etats-unis|\bny\b/, "US"], [/canada/, "CA"], [/luxembourg/, "LU"], [/pays-bas|netherlands/, "NL"]];
  for (const [re, c] of map) if (re.test(t)) return c;
  return "FR";
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return rep(405, { ok: false });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  // Seul le compte CRM de Roméo peut appeler cette fonction
  const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who } = await sb.auth.getUser(jwt);
  if (who?.user?.id !== USER_ID) return rep(403, { ok: false, error: "forbidden" });

  let body: Record<string, any> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return rep(400, { ok: false, error: "payload" }); }
  const token = Deno.env.get("PENNYLANE_API_TOKEN");
  if (body.action === "status") return rep(200, { ok: true, configured: !!token });
  if (!token) return rep(200, { ok: false, error: "not_configured" });

  try {
    if (body.action === "push") {
      const num = String(body.num || "");
      const { data: doc, error } = await sb.from("documents").select("id, num, type, invoice_snapshot, pennylane")
        .eq("user_id", USER_ID).eq("num", num).maybeSingle();
      if (error || !doc) return rep(404, { ok: false, error: "document" });
      if (doc.pennylane?.invoice_id) return rep(200, { ok: true, already: true, invoice_id: doc.pennylane.invoice_id });
      const snap = doc.invoice_snapshot || {};
      if (!snap.invoiceIssuedAt) return rep(400, { ok: false, error: "not_issued" });
      const pdf = String(body.pdf_base64 || "");
      if (pdf.length < 1000) return rep(400, { ok: false, error: "pdf" });

      // 1. Client Pennylane (créé une fois, puis réutilisé)
      const key = customerKey(snap);
      let customerId: number | null = null;
      const { data: link } = await sb.from("pennylane_customers").select("pennylane_customer_id").eq("crm_key", key).maybeSingle();
      if (link) customerId = Number(link.pennylane_customer_id);
      if (!customerId) {
        const det = snap.invoiceDetails || {};
        const name = String(snap.company || snap.clientName || snap.contact || "Client").slice(0, 200);
        const created = await pl(token, "/company_customers", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            name,
            billing_address: splitAddress(snap.billingAddress),
            ...(det.clientVat || snap.customerVatNumber ? { vat_number: det.clientVat || snap.customerVatNumber } : {}),
            ...(det.clientSiren ? { reg_no: det.clientSiren } : {}),
            ...(snap.email ? { emails: [snap.email] } : {}),
            external_reference: key.slice(0, 100),
            payment_conditions: "upon_receipt",
            billing_language: snap.docLocale && snap.docLocale !== "FR" ? "en_GB" : "fr_FR",
          }),
        });
        customerId = Number(created.id);
        await sb.from("pennylane_customers").upsert({ crm_key: key, pennylane_customer_id: customerId, name });
      }

      // 2. PDF de la facture
      const bytes = Uint8Array.from(atob(pdf), (c) => c.charCodeAt(0));
      const form = new FormData();
      form.append("file", new Blob([bytes], { type: "application/pdf" }), `${num}.pdf`);
      const file = await pl(token, "/file_attachments", { method: "POST", body: form });

      // 3. Facture (une ligne de synthèse, montants identiques au PDF)
      const foreign = snap.docCurrency && snap.docCurrency !== "EUR" && Number(snap.ttcCurrency) > 0;
      const vatRate = Number(snap.vatRate) > 0 ? VAT_FR : (snap.vatRegime === "eu-b2b" ? VAT_EU : VAT_EXPORT);
      const curTTC = foreign ? money(snap.ttcCurrency) : money(snap.ttc);
      const curHT = foreign ? money(snap.ttcCurrency) : money(snap.ht);
      const curTax = foreign ? "0.00" : money(snap.tva);
      const label = snap.type === "FAC"
        ? `Acompte ${snap.depositPct || ""} % ${snap.sourceQuoteNum ? "sur devis " + snap.sourceQuoteNum : ""}`.replace(/\s+/g, " ").trim()
        : `Chaises Martingale${snap.qty ? " x" + snap.qty : ""}${snap.sourceQuoteNum ? " (devis " + snap.sourceQuoteNum + ")" : ""}`;
      const imported = await pl(token, "/customer_invoices/import", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          file_attachment_id: file.id,
          customer_id: customerId,
          invoice_number: num,
          external_reference: num,
          date: isoFromFr(snap.date),
          deadline: snap.invoiceDetails?.dueDate || isoFromFr(snap.date),
          currency: foreign ? snap.docCurrency : "EUR",
          currency_amount_before_tax: curHT,
          currency_tax: curTax,
          currency_amount: curTTC,
          ...(foreign ? { amount: money(snap.ttc), tax: "0.00" } : {}),
          ...(snap.invoiceDetails?.purchaseOrder ? { purchase_order_reference: String(snap.invoiceDetails.purchaseOrder).slice(0, 50) } : {}),
          invoice_lines: [{
            label: label.slice(0, 200),
            quantity: 1,
            unit: "piece",
            raw_currency_unit_price: curHT,
            currency_amount: curTTC,
            currency_tax: curTax,
            ...(foreign ? { amount: money(snap.ttc), tax: "0.00" } : {}),
            vat_rate: vatRate,
            substance: "goods",
          }],
        }),
      });
      const link2 = { invoice_id: imported.id, customer_id: customerId, pushed_at: new Date().toISOString() };
      await sb.from("documents").update({ pennylane: link2 }).eq("id", doc.id);
      return rep(200, { ok: true, ...link2 });
    }

    if (body.action === "payments") {
      const { data: docs } = await sb.from("documents").select("id, num, statut, pennylane")
        .eq("user_id", USER_ID).not("pennylane", "is", null);
      const paidNow: string[] = [];
      for (const d of docs || []) {
        if (!d.pennylane?.invoice_id || d.pennylane?.paid) continue;
        const inv = await pl(token, `/customer_invoices/${d.pennylane.invoice_id}`);
        const paid = inv?.paid === true || inv?.status === "paid";
        if (paid) {
          await sb.from("documents").update({ statut: "Payée", pennylane: { ...d.pennylane, paid: true, paid_at: new Date().toISOString() } }).eq("id", d.id);
          paidNow.push(d.num);
        }
      }
      return rep(200, { ok: true, paid: paidNow, checked: (docs || []).length });
    }
    return rep(400, { ok: false, error: "action" });
  } catch (e) {
    console.error("pennylane-sync", e);
    return rep(502, { ok: false, error: "pennylane", detail: String((e as Error).message || e).slice(0, 500) });
  }
});
