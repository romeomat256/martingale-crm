// Martingale : lien client sécurisé vers un devis ou une facture, bon pour accord en ligne,
// et envoi par email (Resend).
//   GET  ?t=TOKEN                                   (public)  -> le document à afficher
//   POST { action: "accept", t, name }               (public)  -> bon pour accord sur un devis
//   POST { action: "link", num }                     (CRM)     -> crée ou réutilise le lien
//   POST { action: "send", num, to, subject, message } (CRM)   -> envoie l'email avec le lien
// Clés facultatives : RESEND_API_KEY, MAIL_FROM (ex. « Martingale Paris <devis@martingaleparis.fr> »).
// verify_jwt = false : les deux actions publiques n'ont pas de session ; les autres vérifient la session.

import { createClient } from "jsr:@supabase/supabase-js@2";

const USER_ID = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const VIEW_URL = Deno.env.get("PUBLIC_DOC_URL") || "https://martingale-crm.vercel.app/document.html";
const REPLY_TO = "romeo@martingaleparis.fr";

function cors(origin: string | null): Record<string, string> {
  const ok = origin && (/^https:\/\/martingale-crm[a-z0-9-]*\.vercel\.app$/.test(origin) || /^http:\/\/localhost:\d+$/.test(origin));
  return {
    "Access-Control-Allow-Origin": ok ? origin! : "https://martingale-crm.vercel.app",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
  };
}

function newToken(): string {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

const esc = (s: string) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json", "Cache-Control": "no-store" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  async function loadLink(t: string) {
    if (!/^[0-9a-f]{48}$/.test(t)) return null;
    const { data } = await sb.from("document_links").select("*").eq("token", t).maybeSingle();
    if (!data || new Date(data.expires_at) < new Date()) return null;
    return data;
  }
  async function loadDoc(num: string) {
    const { data } = await sb.from("documents").select("id, num, type, statut, invoice_snapshot, prospect_id, company, client_name, ttc")
      .eq("user_id", USER_ID).eq("num", num).maybeSingle();
    if (data && data.type === "DEV") {
      // Les devis gardent leur HTML dans document_html (les factures dans invoice_snapshot)
      const { data: h } = await sb.from("document_html").select("html").eq("num", num).eq("user_id", USER_ID).maybeSingle();
      (data as any).html = h?.html || "";
    }
    return data;
  }
  const docHtml = (d: any) => d?.invoice_snapshot?.invoiceHtml || d?.html || "";

  // ── Public : affichage
  if (req.method === "GET") {
    const link = await loadLink(new URL(req.url).searchParams.get("t") || "");
    if (!link) return rep(404, { ok: false, error: "lien" });
    const doc = await loadDoc(link.document_num);
    const html = docHtml(doc);
    if (!doc || !html) return rep(404, { ok: false, error: "document" });
    await sb.from("document_links").update({ views: (link.views || 0) + 1, last_viewed_at: new Date().toISOString() }).eq("token", link.token);
    return rep(200, {
      ok: true, num: doc.num, type: doc.type, html,
      accepted_at: link.accepted_at, accepted_name: link.accepted_name,
      can_accept: doc.type === "DEV" && !link.accepted_at && !["Accepté", "Facturé", "Refusé"].includes(doc.statut || ""),
    });
  }
  if (req.method !== "POST") return rep(405, { ok: false });

  let body: Record<string, any> = {};
  try { body = JSON.parse((await req.text()).slice(0, 20000) || "{}"); } catch { return rep(400, { ok: false, error: "payload" }); }

  // ── Public : bon pour accord
  if (body.action === "accept") {
    const link = await loadLink(String(body.t || ""));
    if (!link) return rep(404, { ok: false, error: "lien" });
    const name = String(body.name || "").trim().slice(0, 120);
    if (name.length < 2) return rep(400, { ok: false, error: "nom" });
    const doc = await loadDoc(link.document_num);
    if (!doc || doc.type !== "DEV") return rep(400, { ok: false, error: "type" });
    if (link.accepted_at) return rep(200, { ok: true, already: true });
    const now = new Date().toISOString();
    const meta = { ip: req.headers.get("x-forwarded-for") || "", ua: (req.headers.get("user-agent") || "").slice(0, 200) };
    await sb.from("document_links").update({ accepted_at: now, accepted_name: name, accepted_meta: meta }).eq("token", link.token);
    if (!["Facturé", "Refusé"].includes(doc.statut || "")) await sb.from("documents").update({ statut: "Accepté" }).eq("id", doc.id);
    if (doc.prospect_id) {
      const { data: p } = await sb.from("prospects").select("notes").eq("id", doc.prospect_id).maybeSingle();
      const note = `--- ${now.slice(0, 16).replace("T", " ")} · Devis ${doc.num} accepté en ligne par ${name}`;
      await sb.from("prospects").update({ notes: p?.notes ? `${p.notes}\n\n${note}` : note, statut: "Gagné", date_updated: now }).eq("id", doc.prospect_id);
    }
    return rep(200, { ok: true });
  }

  // ── CRM : session de Roméo obligatoire
  const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who } = await sb.auth.getUser(jwt);
  if (who?.user?.id !== USER_ID) return rep(403, { ok: false, error: "forbidden" });

  async function ensureLink(num: string) {
    const { data: ex } = await sb.from("document_links").select("token, expires_at").eq("document_num", num)
      .gt("expires_at", new Date().toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
    const token = ex?.token || newToken();
    if (!ex) await sb.from("document_links").insert({ token, user_id: USER_ID, document_num: num });
    return `${VIEW_URL}?t=${token}`;
  }

  const num = String(body.num || "");
  const doc = await loadDoc(num);
  if (!doc) return rep(404, { ok: false, error: "document" });
  if (!docHtml(doc)) return rep(400, { ok: false, error: "no_html" });

  if (body.action === "link") return rep(200, { ok: true, url: await ensureLink(num) });

  if (body.action === "send") {
    const to = String(body.to || "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return rep(400, { ok: false, error: "email" });
    const url = await ensureLink(num);
    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return rep(200, { ok: false, error: "not_configured", url });
    const subject = String(body.subject || `Martingale Paris · ${num}`).slice(0, 200);
    const message = String(body.message || "").slice(0, 5000);
    const isQuote = doc.type === "DEV";
    const en = body.lang === "en";
    const html = `<div style="font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;color:#1F1F1A;max-width:560px">
${esc(message).replace(/\n/g, "<br>")}
<p style="margin:28px 0"><a href="${url}" style="background:#4D5038;color:#F7F5F0;text-decoration:none;padding:12px 20px;border-radius:6px;font-weight:700">${en ? (isQuote ? "View quote" : "View invoice") : (isQuote ? "Voir le devis" : "Voir la facture")} ${esc(num)}</a></p>
<p style="color:#6B6B5E;font-size:13px">${en ? `The document opens in your browser. You can print it or save it as a PDF${isQuote ? ", and approve it online" : ""}.` : `Le document s’ouvre dans votre navigateur. Vous pouvez l’imprimer ou l’enregistrer en PDF${isQuote ? ", et donner votre accord en ligne" : ""}.`}</p>
<p style="color:#8A8A7C;font-size:12px;margin-top:28px">MARTINGALE · 30 rue de l’Étang, 64600 Anglet${en ? ", France" : ""} · martingaleparis.fr</p></div>`;
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: Deno.env.get("MAIL_FROM") || "Martingale Paris <devis@martingaleparis.fr>",
        to: [to], reply_to: REPLY_TO, bcc: [REPLY_TO], subject, html,
        text: `${message}\n\n${url}`,
      }),
    });
    const out = await r.json().catch(() => ({}));
    if (!r.ok) return rep(502, { ok: false, error: "envoi", detail: JSON.stringify(out).slice(0, 300), url });
    if (doc.prospect_id) {
      const { data: p } = await sb.from("prospects").select("notes").eq("id", doc.prospect_id).maybeSingle();
      const note = `--- ${new Date().toISOString().slice(0, 16).replace("T", " ")} · ${num} envoyé par email à ${to}`;
      await sb.from("prospects").update({ notes: p?.notes ? `${p.notes}\n\n${note}` : note, date_updated: new Date().toISOString() }).eq("id", doc.prospect_id);
    }
    return rep(200, { ok: true, sent: true, url });
  }
  return rep(400, { ok: false, error: "action" });
});
