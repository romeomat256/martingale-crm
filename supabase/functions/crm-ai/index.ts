// Martingale : IA du CRM (Claude, API Anthropic).
// Action « appel » : lit le résumé d'un appel et rend, sous forme structurée,
//   - la suite à donner (devis à préparer, à rappeler, sans suite, simple contact) ;
//   - la date de rappel si le résumé en donne une ;
//   - ce qu'il faut pour le devis : modèles du catalogue et quantités, département, remise, délai, besoin en une phrase.
// Le CRM n'enregistre rien d'ici : il reçoit le résultat, le vérifie et l'applique à la fiche.
// Clé : ANTHROPIC_API_KEY (Supabase > Edge Functions > Secrets). Sans elle, réponse { error: "not_configured" }
// et le CRM se replie sur ses règles.
// Appel : membre de l'équipe connecté uniquement.

import { createClient } from "jsr:@supabase/supabase-js@2";

const OWNER = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const MODEL = Deno.env.get("ANTHROPIC_MODEL") || "claude-haiku-5-5";

function cors(origin: string | null): Record<string, string> {
  const ok = origin && (/^https:\/\/martingale-crm[a-z0-9-]*\.vercel\.app$/.test(origin) || /^http:\/\/localhost:\d+$/.test(origin));
  return {
    "Access-Control-Allow-Origin": ok ? origin! : "https://martingale-crm.vercel.app",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const TOOL = {
  name: "classer_appel",
  description: "Enregistre ce que le résumé d'appel apprend sur la demande du client.",
  input_schema: {
    type: "object",
    properties: {
      suite: {
        type: "string",
        enum: ["devis", "rappel", "sans_suite", "contacte"],
        description: "devis : le client attend un devis ou un chiffrage. rappel : il faut le rappeler, sans devis demandé pour l'instant. sans_suite : il n'est pas intéressé, a choisi ailleurs, annule. contacte : simple échange, rien à faire de plus.",
      },
      rappel_date: { type: "string", description: "Date de rappel AAAA-MM-JJ si le résumé en donne une (« lundi », « dans 15 jours », « début janvier » = le 5). Sinon chaîne vide." },
      produits: {
        type: "array",
        description: "Chaises du catalogue demandées. Seulement des id du catalogue fourni. Vide si aucun modèle n'est cité.",
        items: {
          type: "object",
          properties: { id: { type: "string" }, qty: { type: "integer", minimum: 1 } },
          required: ["id", "qty"],
        },
      },
      qty: { type: "integer", minimum: 0, description: "Nombre total de chaises voulu, même si le modèle n'est pas choisi. 0 si inconnu." },
      dept: { type: "string", description: "Département de livraison (2 ou 3 chiffres) s'il est donné ou déductible d'une ville française connue. Sinon chaîne vide." },
      ville: { type: "string", description: "Ville du client ou de livraison si citée. Sinon chaîne vide." },
      remise_pct: { type: "number", minimum: 0, maximum: 50, description: "Remise promise en %, 0 si aucune." },
      delai: { type: "string", description: "Échéance du client en quelques mots (« pour mars », « ouverture le 15 avril »). Sinon chaîne vide." },
      besoin: { type: "string", description: "Le besoin en une phrase courte, sans répéter les quantités." },
      manque: { type: "array", items: { type: "string" }, description: "Ce qui manque pour faire le devis, en quelques mots chacun (« modèle à préciser »). Vide si rien." },
    },
    required: ["suite", "rappel_date", "produits", "qty", "dept", "ville", "remise_pct", "delai", "besoin", "manque"],
  },
};

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return rep(405, { ok: false });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who } = await sb.auth.getUser(jwt);
  const uid = who?.user?.id;
  let allowed = uid === OWNER;
  if (!allowed && uid) {
    const { data: m } = await sb.from("crm_members").select("owner_id").eq("user_id", uid).maybeSingle();
    allowed = m?.owner_id === OWNER;
  }
  if (!allowed) return rep(403, { ok: false, error: "forbidden" });

  let body: Record<string, any> = {};
  try { body = JSON.parse((await req.text()).slice(0, 20000) || "{}"); } catch { return rep(400, { ok: false, error: "payload" }); }
  if (body.action !== "appel") return rep(400, { ok: false, error: "action" });

  const key = Deno.env.get("ANTHROPIC_API_KEY") || "";
  if (!key) return rep(200, { ok: false, error: "not_configured" });

  const summary = String(body.summary || "").trim().slice(0, 4000);
  if (!summary) return rep(400, { ok: false, error: "vide" });
  const catalog = (Array.isArray(body.catalog) ? body.catalog : []).slice(0, 60)
    .map((p: any) => ({ id: String(p.id || ""), name: String(p.name || "") })).filter((p: any) => p.id && p.name);
  const fiche = body.fiche || {};
  const today = String(body.today || new Date().toISOString().slice(0, 10));

  const system = [
    "Tu aides Martingale Paris, qui vend des chaises bistrot en rotin aux cafés, hôtels et restaurants.",
    "On te donne le résumé d'un appel écrit vite par le gérant, et ce que la fiche client contient déjà.",
    "Tu remplis l'outil classer_appel. Tu n'inventes rien : un champ inconnu reste vide ou à 0.",
    "Les modèles se reconnaissent à leur couleur (« kaki » = Kaki Botanique, « bleues » = Bleu Atelier...). N'utilise que les id du catalogue.",
    "Un prénom, une enseigne ou une ville qui ressemble à une couleur n'est pas un modèle.",
    `Nous sommes le ${today} (${body.weekday || ""}), à Paris.`,
  ].join("\n");
  const user = [
    "Catalogue (id : nom) :",
    ...catalog.map((p: any) => `- ${p.id} : ${p.name}`),
    "",
    "Fiche actuelle :",
    JSON.stringify({ nom: fiche.name || "", ville: fiche.ville || "", dept: fiche.dept || "", produits: fiche.produits || [], qty: fiche.qty || 0, statut: fiche.statut || "" }),
    "",
    "Résumé de l'appel :",
    summary,
  ].join("\n");

  let out: any = null;
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12000);
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      signal: ctrl.signal,
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 900,
        system,
        tools: [TOOL],
        tool_choice: { type: "tool", name: TOOL.name },
        messages: [{ role: "user", content: user }],
      }),
    });
    clearTimeout(timer);
    const text = await res.text();
    if (!res.ok) return rep(200, { ok: false, error: "api", detail: `${res.status} ${text.slice(0, 200)}` });
    const j = JSON.parse(text);
    out = (j.content || []).find((c: any) => c.type === "tool_use")?.input || null;
  } catch (e) {
    return rep(200, { ok: false, error: "api", detail: String((e as Error)?.message || e).slice(0, 200) });
  }
  if (!out) return rep(200, { ok: false, error: "vide" });

  // Contrôle de ce que l'IA rend : seulement des modèles connus, des nombres plausibles, une date à venir.
  const ids = new Set(catalog.map((p: any) => p.id));
  const produits = (Array.isArray(out.produits) ? out.produits : [])
    .filter((p: any) => ids.has(String(p.id)) && Number(p.qty) >= 1 && Number(p.qty) <= 5000)
    .map((p: any) => ({ id: String(p.id), qty: Math.round(Number(p.qty)) }));
  const date = /^\d{4}-\d{2}-\d{2}$/.test(String(out.rappel_date || "")) && String(out.rappel_date) >= today ? String(out.rappel_date) : "";
  const result = {
    suite: ["devis", "rappel", "sans_suite", "contacte"].includes(out.suite) ? out.suite : "contacte",
    rappel_date: date,
    produits,
    qty: Math.max(Math.min(Math.round(Number(out.qty) || 0), 5000), produits.reduce((s: number, p: any) => s + p.qty, 0)),
    dept: /^\d{2,3}$/.test(String(out.dept || "")) ? String(out.dept) : "",
    ville: String(out.ville || "").slice(0, 60),
    remise_pct: Math.min(Math.max(Number(out.remise_pct) || 0, 0), 50),
    delai: String(out.delai || "").slice(0, 80),
    besoin: String(out.besoin || "").slice(0, 200),
    manque: (Array.isArray(out.manque) ? out.manque : []).map((x: any) => String(x).slice(0, 60)).slice(0, 5),
  };
  return rep(200, { ok: true, source: "ia", model: MODEL, result });
});
