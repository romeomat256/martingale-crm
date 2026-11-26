// Martingale : échanges clients (Gmail, WhatsApp) vers le CRM.
// Chaque message reçu est rattaché à une fiche (prospects) par e-mail ou par téléphone,
// puis enregistré dans la table messages. Un message sans fiche correspondante n'est pas conservé.
// Sécurité : clé partagée MESSAGES_INGEST_SECRET dans l'en-tête x-crm-secret.
// verify_jwt = false : l'appelant (script Google, webhook) n'a pas de jeton Supabase.
//
// GET  -> { emails: [...], phones: [...] } : contacts connus du CRM, pour filtrer à la source.
// POST -> { canal: "gmail" | "whatsapp", self?: [adresses de Martingale], messages: [...] }
//         message : { external_id, direction: "in" | "out", from, to, subject?, content?,
//                     sent_at?, thread_id?, attachments?: [{ name, size, type }] }
//         candidats (facultatif) : mails reçus d'expéditeurs inconnus, déjà filtrés par le script Gmail.
//         { external_id, from, from_name?, to, subject?, content?, sent_at? } -> table mail_candidates,
//         triés ensuite par le serveur (fonction crm-ai) : rien n'entre dans les fiches sans ce tri.

import { createClient } from "jsr:@supabase/supabase-js@2";

const USER_ID = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const CANAUX = new Set(["gmail", "whatsapp"]);
const MAX_BATCH = 100;
const MAX_CONTENT = 20000;

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function sameSecret(given: string | null, expected: string): boolean {
  if (!given || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

// "Prénom Nom <a@b.fr>, c@d.fr" -> ["a@b.fr", "c@d.fr"]
function emailsOf(v: unknown): string[] {
  return String(v ?? "").toLowerCase().match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/g) || [];
}

// Clé de téléphone : les 9 derniers chiffres (06 12 34 56 78, +33 6 12 34 56 78 et 0033612345678 donnent la même clé).
function phoneKey(v: unknown): string {
  const d = String(v ?? "").replace(/\D/g, "");
  return d.length >= 9 ? d.slice(-9) : "";
}

const cut = (v: unknown, max: number) => {
  const s = String(v ?? "");
  return s.length > max ? s.slice(0, max) : s;
};

Deno.serve(async (req: Request) => {
  const secret = Deno.env.get("MESSAGES_INGEST_SECRET");
  if (!secret) return json(503, { ok: false, error: "not_configured" });
  if (!sameSecret(req.headers.get("x-crm-secret"), secret)) return json(401, { ok: false, error: "secret" });
  if (req.method !== "GET" && req.method !== "POST") return json(405, { ok: false });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  // Contacts du CRM. Tri par date : en cas de doublon, la fiche la plus récemment modifiée l'emporte.
  const { data: contacts, error: contactsError } = await sb.from("prospects")
    .select("id, email, tel, date_updated")
    .eq("user_id", USER_ID)
    .order("date_updated", { ascending: true });
  if (contactsError) {
    console.error("contacts", contactsError);
    return json(500, { ok: false, error: "contacts" });
  }
  const byEmail = new Map<string, string>();
  const byPhone = new Map<string, string>();
  for (const c of contacts || []) {
    for (const e of emailsOf(c.email)) byEmail.set(e, c.id);
    const k = phoneKey(c.tel);
    if (k) byPhone.set(k, c.id);
  }

  if (req.method === "GET") {
    return json(200, { ok: true, emails: [...byEmail.keys()], phones: [...byPhone.keys()] });
  }

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return json(400, { ok: false, error: "payload" }); }
  const canal = String(body?.canal || "");
  if (!CANAUX.has(canal)) return json(400, { ok: false, error: "canal" });
  const candidats = canal === "gmail" && Array.isArray(body?.candidats) ? body.candidats.slice(0, 50) : [];
  const list = Array.isArray(body?.messages) ? body.messages : (candidats.length ? [] : null);
  if (!list) return json(400, { ok: false, error: "messages" });
  if (list.length > MAX_BATCH) return json(413, { ok: false, error: "too_many", max: MAX_BATCH });

  // Adresses et numéros de Martingale : jamais utilisés pour rattacher un message à une fiche.
  const selfEmails = new Set<string>((Array.isArray(body?.self) ? body.self : []).flatMap((v: unknown) => emailsOf(v)));

  // Mails d'inconnus : mis de côté pour le tri, jamais rattachés directement à une fiche.
  let candidatsGardes = 0;
  if (candidats.length) {
    const rowsC: Record<string, unknown>[] = [];
    for (const c of candidats) {
      const externalId = cut(c?.external_id, 200).trim();
      const sender = emailsOf(c?.from)[0] || "";
      if (!externalId || !sender || selfEmails.has(sender) || byEmail.has(sender)) continue;
      const t = Date.parse(String(c?.sent_at || ""));
      rowsC.push({
        user_id: USER_ID,
        external_id: externalId,
        from_addr: cut(c?.from, 300) || null,
        from_name: cut(c?.from_name, 120) || null,
        to_addr: cut(c?.to, 500) || null,
        subject: cut(c?.subject, 300) || null,
        content: cut(c?.content, 6000) || null,
        sent_at: new Date(Number.isFinite(t) ? t : Date.now()).toISOString(),
      });
    }
    if (rowsC.length) {
      const { data: already } = await sb.from("messages").select("external_id").eq("canal", "gmail").in("external_id", rowsC.map((r) => r.external_id as string));
      const seen = new Set((already || []).map((r: any) => r.external_id));
      const fresh = rowsC.filter((r) => !seen.has(r.external_id as string));
      if (fresh.length) {
        const { data, error } = await sb.from("mail_candidates").upsert(fresh, { onConflict: "external_id", ignoreDuplicates: true }).select("id");
        if (error) console.error("candidats", error);
        else candidatsGardes = data?.length || 0;
      }
    }
  }
  const selfPhones = new Set<string>((Array.isArray(body?.self) ? body.self : []).map((v: unknown) => phoneKey(v)).filter(Boolean));

  const rows: Record<string, unknown>[] = [];
  let skipped = 0;
  for (const m of list) {
    const externalId = cut(m?.external_id, 200).trim();
    const direction = m?.direction === "out" ? "out" : m?.direction === "in" ? "in" : "";
    if (!externalId || !direction) { skipped++; continue; }

    // Le correspondant : l'expéditeur pour un message reçu, le destinataire pour un message envoyé.
    const other = direction === "in" ? m?.from : m?.to;
    let prospectId: string | null = null;
    if (canal === "gmail") {
      const candidates = [...emailsOf(other), ...emailsOf(m?.from), ...emailsOf(m?.to)];
      for (const e of candidates) {
        if (selfEmails.has(e)) continue;
        const id = byEmail.get(e);
        if (id) { prospectId = id; break; }
      }
    } else {
      for (const k of [phoneKey(other), phoneKey(m?.from), phoneKey(m?.to)]) {
        if (!k || selfPhones.has(k)) continue;
        const id = byPhone.get(k);
        if (id) { prospectId = id; break; }
      }
    }
    if (!prospectId) { skipped++; continue; }

    const t = Date.parse(String(m?.sent_at || ""));
    const attachments = (Array.isArray(m?.attachments) ? m.attachments : []).slice(0, 20).map((a: any) => ({
      name: cut(a?.name, 200),
      size: Number(a?.size) || 0,
      type: cut(a?.type, 100),
    }));
    rows.push({
      user_id: USER_ID,
      prospect_id: prospectId,
      canal,
      direction,
      external_id: externalId,
      thread_id: cut(m?.thread_id, 200) || null,
      from_addr: cut(m?.from, 500) || null,
      to_addr: cut(m?.to, 1000) || null,
      subject: cut(m?.subject, 500) || null,
      content: cut(m?.content, MAX_CONTENT) || null,
      sent_at: new Date(Number.isFinite(t) ? t : Date.now()).toISOString(),
      attachments,
    });
  }

  let stored = 0;
  if (rows.length) {
    // Un message déjà enregistré n'est ni dupliqué ni réécrit.
    const { data, error } = await sb.from("messages")
      .upsert(rows, { onConflict: "canal,external_id", ignoreDuplicates: true })
      .select("id");
    if (error) {
      console.error("messages", error);
      return json(500, { ok: false, error: "messages" });
    }
    stored = data?.length || 0;
  }
  return json(200, { ok: true, received: list.length, matched: rows.length, stored, skipped, candidats: candidats.length, candidats_gardes: candidatsGardes });
});
