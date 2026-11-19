// Martingale : rapprochement bancaire automatique.
// Lit les encaissements dans Pennylane, les enregistre dans bank_receipts, les rattache aux devis,
// factures et fiches du CRM (fonction SQL crm_match_receipt), puis rattache dans Pennylane la
// transaction à la facture correspondante.
//
// Appels :
//   - programmé (pg_cron -> pg_net) avec l'en-tête x-crm-cron ;
//   - depuis le CRM, par un membre de l'équipe connecté (bouton « Actualiser »).
// Corps JSON facultatif : { "since": "AAAA-MM-JJ" } pour relire depuis une date.
// Clé : PENNYLANE_API_TOKEN, avec les droits « transactions » (lecture) et « customer_invoices ».

import { createClient } from "jsr:@supabase/supabase-js@2";

const API = "https://app.pennylane.com/api/external/v2";
const FALLBACK_OWNER = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const FULL_EFFECT_DAYS = 21;   // au-delà, un encaissement découvert est traité comme de l'historique
const DEFAULT_WINDOW_DAYS = 21;

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

const isoDay = (d: Date) => d.toISOString().slice(0, 10);
const daysAgo = (n: number) => isoDay(new Date(Date.now() - n * 86400000));

async function pl(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...(init.headers || {}) },
  });
  const text = await res.text();
  let body: any = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = { raw: text.slice(0, 300) }; }
  return { ok: res.ok, status: res.status, body };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return rep(405, { ok: false });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Qui appelle ? La tâche programmée (secret gardé dans la base) ou un membre de l'équipe.
  let owner: string | null = null;
  const cronSecret = req.headers.get("x-crm-cron") || "";
  if (cronSecret) {
    const { data: ok } = await sb.rpc("crm_cron_secret_ok", { p: cronSecret });
    if (ok !== true) return rep(403, { ok: false, error: "forbidden" });
    const { data: m } = await sb.from("crm_members").select("owner_id").limit(1).maybeSingle();
    owner = m?.owner_id || FALLBACK_OWNER;
  } else {
    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: who } = await sb.auth.getUser(jwt);
    if (!who?.user?.id) return rep(403, { ok: false, error: "forbidden" });
    const { data: m } = await sb.from("crm_members").select("owner_id").eq("user_id", who.user.id).maybeSingle();
    if (!m?.owner_id) return rep(403, { ok: false, error: "forbidden" });
    owner = m.owner_id;
  }

  let body: Record<string, any> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { /* corps vide accepté */ }
  const token = Deno.env.get("PENNYLANE_API_TOKEN");
  if (!token) return rep(200, { ok: false, error: "not_configured" });

  const since = /^\d{4}-\d{2}-\d{2}$/.test(String(body.since || "")) ? String(body.since) : daysAgo(DEFAULT_WINDOW_DAYS);
  const out = { ok: true, since, lus: 0, nouveaux: 0, rapproches: 0, a_confirmer: 0, pennylane: 0, erreurs: [] as string[] };

  try {
    // 1. Encaissements dans Pennylane
    const filter = encodeURIComponent(JSON.stringify([{ field: "date", operator: "gteq", value: since }]));
    const incoming: { id: number; date: string; amount: number; currency: string; label: string }[] = [];
    let cursor = "";
    for (let page = 0; page < 30; page++) {
      const r = await pl(token, `/transactions?limit=100&filter=${filter}${cursor ? "&cursor=" + encodeURIComponent(cursor) : ""}`);
      if (!r.ok) {
        const scope = r.status === 403 || r.status === 401;
        return rep(200, { ok: false, error: scope ? "scope_transactions" : "pennylane", status: r.status, detail: JSON.stringify(r.body).slice(0, 300) });
      }
      const items: any[] = r.body?.items || r.body?.transactions || [];
      for (const t of items) {
        out.lus++;
        const amount = Number(t.amount ?? t.currency_amount);
        const dir = String(t.direction || "").toLowerCase();
        const isIn = dir ? (dir === "in" || dir === "credit") : amount > 0;
        if (!isIn || !Number.isFinite(amount) || !t.id || !t.date) continue;
        incoming.push({ id: Number(t.id), date: String(t.date).slice(0, 10), amount: Math.abs(amount), currency: String(t.currency || "EUR"), label: String(t.label || t.description || "").slice(0, 2000) });
      }
      cursor = r.body?.next_cursor || "";
      if (!r.body?.has_more || !cursor) break;
    }

    // 2. Enregistrement : les lignes déjà connues gardent leur état, seul le libellé est rafraîchi tant que rien n'est décidé
    const ids = incoming.map((t) => t.id);
    const known = new Map<number, any>();
    for (let i = 0; i < ids.length; i += 200) {
      const { data } = await sb.from("bank_receipts").select("id, label, applied, decided_at").in("id", ids.slice(i, i + 200));
      for (const row of data || []) known.set(Number(row.id), row);
    }
    const fresh: number[] = [];
    for (const t of incoming) {
      const k = known.get(t.id);
      if (!k) {
        const { error } = await sb.from("bank_receipts").insert({ id: t.id, user_id: owner, date: t.date, amount: t.amount, currency: t.currency, label: t.label, source: "api" });
        if (error) out.erreurs.push(`insert ${t.id} : ${error.message}`.slice(0, 200));
        else { fresh.push(t.id); out.nouveaux++; }
      } else if (!k.applied && !k.decided_at && t.label && t.label.length > String(k.label || "").length) {
        await sb.from("bank_receipts").update({ label: t.label }).eq("id", t.id);
      }
    }

    // 3. Rapprochement : les nouveaux, puis ceux restés sans réponse (un devis a pu être créé depuis)
    const limitFull = daysAgo(FULL_EFFECT_DAYS);
    const { data: pending } = await sb.from("bank_receipts").select("id, date")
      .eq("user_id", owner).in("status", ["nouveau", "propose"]).is("decided_at", null).gte("date", daysAgo(60));
    const todo = new Map<number, string>();
    for (const p of pending || []) todo.set(Number(p.id), String(p.date));
    for (const t of incoming) if (fresh.includes(t.id)) todo.set(t.id, t.date);
    for (const [id, date] of todo) {
      const { data: status, error } = await sb.rpc("crm_match_receipt", { p_id: id, p_mode: date >= limitFull ? "complet" : "historique" });
      if (error) { out.erreurs.push(`match ${id} : ${error.message}`.slice(0, 200)); continue; }
      if (status === "rapproche") out.rapproches++;
      else if (status === "propose" || status === "nouveau") out.a_confirmer++;
    }

    // 4. Dans Pennylane : la transaction est rattachée à la facture réglée
    const { data: toLink } = await sb.from("bank_receipts").select("id, document_num, pennylane_note")
      .eq("user_id", owner).eq("status", "rapproche").is("pennylane_matched_at", null)
      .not("document_num", "is", null).neq("document_type", "DEV").gte("date", daysAgo(120));
    for (const b of toLink || []) {
      const { data: doc } = await sb.from("documents").select("pennylane").eq("user_id", owner).eq("num", b.document_num)
        .not("invoice_issued_at", "is", null).maybeSingle();
      const invoiceId = doc?.pennylane?.invoice_id;
      if (!invoiceId) continue; // la facture n'est pas encore dans Pennylane : nouvel essai au prochain passage
      const r = await pl(token, `/customer_invoices/${invoiceId}/matched_transactions`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ transaction_id: Number(b.id) }),
      });
      if (r.ok) {
        await sb.from("bank_receipts").update({ pennylane_matched_at: new Date().toISOString(), pennylane_note: null }).eq("id", b.id);
        out.pennylane++;
      } else {
        const note = `Pennylane ${r.status} : ${JSON.stringify(r.body).slice(0, 200)}`;
        // 422 : en général déjà rattachée dans Pennylane. On note et on n'insiste pas.
        await sb.from("bank_receipts").update({ pennylane_note: note, ...(r.status === 422 ? { pennylane_matched_at: new Date().toISOString() } : {}) }).eq("id", b.id);
        if (r.status !== 422) out.erreurs.push(`${b.document_num} : ${note}`.slice(0, 200));
      }
    }

    await sb.from("crm_sync_state").upsert({ key: "banque_passage", value: { at: new Date().toISOString(), ...out, erreurs: out.erreurs.slice(0, 5) }, updated_at: new Date().toISOString() });
    return rep(200, out);
  } catch (e) {
    console.error("pennylane-bank", e);
    return rep(502, { ok: false, error: "pennylane", detail: String((e as Error).message || e).slice(0, 300) });
  }
});
