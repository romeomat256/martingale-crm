// Martingale : IA du CRM (Claude, API Anthropic).
// Action « appel » : lit le résumé d'un appel et rend, sous forme structurée,
//   - la suite à donner (devis à préparer, à rappeler, sans suite, simple contact) ;
//   - la date de rappel si le résumé en donne une ;
//   - ce qu'il faut pour le devis : modèles du catalogue et quantités, département, remise, délai, besoin en une phrase.
// Le CRM n'enregistre rien d'ici : il reçoit le résultat, le vérifie et l'applique à la fiche.
// Action « candidat » (appelée par la base) : trie un mail d'expéditeur inconnu. Fiche créée seulement si l'IA est sûre
//   qu'il s'agit d'une demande client ; « à vérifier » si c'est possible ; sinon le mail est vidé (rien n'est gardé).
//   Sans clé IA, des règles prudentes ne font jamais mieux que « à vérifier ».
// Action « mail » (appelée par la base) : lit un mail reçu d'un client et propose, si c'est clair, un déplacement
//   (gagné, perdu, devis à préparer, en attente). Rien n'est appliqué sans un clic dans le CRM.
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
        enum: ["devis", "rappel", "attente", "sans_suite", "contacte"],
        description: "devis : le client attend un devis ou un chiffrage. rappel : il faut le rappeler bientôt, sans devis demandé pour l'instant. attente : le projet est reporté ou long (travaux, permis, financement, associés, « plus tard », « l'an prochain ») ; c'est le cas le plus courant dans le mobilier, ce n'est pas un refus. sans_suite : seulement si le client dit clairement non (pas intéressé, a choisi ailleurs, annule). contacte : simple échange, rien à faire de plus.",
      },
      rappel_date: { type: "string", description: "Date de rappel AAAA-MM-JJ si le résumé en donne une (« lundi », « dans 15 jours », « début janvier » = le 5). Pour « attente » sans date donnée, dans 30 jours. Sinon chaîne vide." },
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

const TRI_TOOL = {
  name: "trier_mail",
  description: "Dit si un mail reçu d'un inconnu est une demande d'un client professionnel pour des chaises (ou du mobilier) Martingale.",
  input_schema: {
    type: "object",
    properties: {
      demande_client: { type: "boolean", description: "Vrai seulement si l'expéditeur demande un prix, un devis, des informations sur les chaises, un échantillon ou une commande, pour un établissement (café, restaurant, hôtel, bureau...) ou un projet de décoration." },
      nature: { type: "string", enum: ["demande_devis", "question_produit", "autre_client", "fournisseur", "prospection_commerciale", "candidature", "personnel", "administratif", "publicite", "autre"] },
      confiance: { type: "number", minimum: 0, maximum: 1, description: "Certitude que c'est une vraie demande client. 0.9 et plus : sans aucun doute." },
      resume: { type: "string", description: "La demande en une ou deux phrases courtes, en français. Vide si ce n'est pas une demande client." },
      fiche: {
        type: "object",
        properties: {
          name: { type: "string", description: "Nom de l'établissement s'il est donné (signature, texte, nom de domaine professionnel). Sinon vide." },
          contact: { type: "string", description: "Prénom et nom de l'expéditeur." },
          tel: { type: "string" }, ville: { type: "string" }, dept: { type: "string", description: "2 ou 3 chiffres, sinon vide." },
          qty: { type: "integer", minimum: 0 },
          produits: { type: "array", items: { type: "object", properties: { id: { type: "string" }, qty: { type: "integer", minimum: 1 } }, required: ["id", "qty"] } },
        },
        required: ["name", "contact", "tel", "ville", "dept", "qty", "produits"],
      },
    },
    required: ["demande_client", "nature", "confiance", "resume", "fiche"],
  },
};

const MAIL_TOOL = {
  name: "lire_mail",
  description: "Dit si le mail d'un client change l'état de son dossier.",
  input_schema: {
    type: "object",
    properties: {
      proposition: {
        type: "string", enum: ["gagne", "perdu", "devis", "attente", "rien"],
        description: "gagne : le client valide le devis ou passe commande (« bon pour accord », « on valide », « vous pouvez lancer »). perdu : il refuse clairement (autre fournisseur, abandon du projet). devis : il demande un devis, un nouveau chiffrage ou une modification de devis. attente : il reporte (travaux, financement, « on revient vers vous en mars »). rien : tout le reste (questions, remerciements, livraison, facture...). En cas de doute : rien.",
      },
      confiance: { type: "number", minimum: 0, maximum: 1 },
      raison: { type: "string", description: "En quelques mots, ce que dit le client (« valide le devis DEV-... », « reporte à mars »)." },
    },
    required: ["proposition", "confiance", "raison"],
  },
};

async function askClaude(key: string, system: string, user: string, tool: any): Promise<{ out?: any; error?: string }> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 20000);
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST", signal: ctrl.signal,
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 900, system, tools: [tool], tool_choice: { type: "tool", name: tool.name }, messages: [{ role: "user", content: user }] }),
    });
    clearTimeout(timer);
    const text = await res.text();
    if (!res.ok) return { error: `${res.status} ${text.slice(0, 200)}` };
    const j = JSON.parse(text);
    return { out: (j.content || []).find((c: any) => c.type === "tool_use")?.input || null };
  } catch (e) {
    return { error: String((e as Error)?.message || e).slice(0, 200) };
  }
}

const norm = (v: unknown) => String(v ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
const emailOf = (v: unknown) => (String(v ?? "").toLowerCase().match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/) || [""])[0];

// Sans IA : un mail d'inconnu n'est gardé (« à vérifier ») que s'il parle clairement de chaises et d'un établissement.
function triRegles(subject: string, content: string) {
  const t = norm(subject + " " + content).slice(0, 6000);
  const produit = /\b(chaises?|rotin|bistrot|cannage|assises?|terrasse|mobilier)\b/.test(t);
  const demande = /\b(devis|tarifs?|prix|cotation|catalogue|echantillons?|disponibilite|commander|commande)\b/.test(t);
  const lieu = /\b(restaurant|cafe|hotel|brasserie|bar|bistro|terrasse|etablissement|boutique|architecte|decoratrice|decorateur)\b/.test(t);
  const bruit = /\b(desinscri|unsubscribe|newsletter|webinar|offre speciale|promotion|candidature|cv|facture n|votre commande n)\b/.test(t);
  const score = (produit ? 1 : 0) + (demande ? 1 : 0) + (lieu ? 1 : 0) - (bruit ? 2 : 0);
  return { garder: score >= 2, nature: score >= 2 ? (demande ? "demande_devis" : "question_produit") : "autre", confiance: score >= 3 ? 0.7 : score >= 2 ? 0.55 : 0.1 };
}

// Sans IA : seules des formules sans ambiguïté donnent une proposition.
function mailRegles(subject: string, content: string) {
  // Seul le message du client compte : on coupe à la première citation (« Le … a écrit », « De : », « ----- »).
  // L'objet n'est pas lu : « Re: devis » est l'objet de toutes les réponses à un devis.
  const first = (norm(content).split(/\n\s*(?:>|le .{3,80} a ecrit|on .{3,80} wrote|-----|de :|from:)/)[0]).slice(0, 3000);
  void subject;
  if (/\b(bon pour accord|nous validons|on valide|je valide|c.est valide|devis (est )?valide|vous pouvez lancer|go pour la commande|nous passons commande|je passe commande)\b/.test(first)) return { proposition: "gagne", confiance: 0.7, raison: "le client valide" };
  if (/\b(ne (donnerons|donnera) pas suite|pas donner suite|autre fournisseur|avons choisi un autre|projet (est )?(abandonne|annule)|nous renoncons)\b/.test(first)) return { proposition: "perdu", confiance: 0.7, raison: "le client renonce" };
  if (/\b(reporte|repousse|decale|pas pour (le moment|l.instant)|revenons vers vous|reviendrons vers vous|plus tard|l.annee prochaine)\b/.test(first)) return { proposition: "attente", confiance: 0.6, raison: "le client reporte" };
  if (/\b(devis|chiffrage|cotation|tarif pour|prix pour|nouvelle proposition)\b/.test(first)) return { proposition: "devis", confiance: 0.55, raison: "le client demande un chiffrage" };
  return { proposition: "rien", confiance: 0, raison: "" };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return rep(405, { ok: false });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let fromBase = false, allowed = false;
  const cronSecret = req.headers.get("x-crm-cron") || "";
  if (cronSecret) {
    const { data: ok } = await sb.rpc("crm_cron_secret_ok", { p: cronSecret });
    if (ok !== true) return rep(403, { ok: false, error: "forbidden" });
    fromBase = allowed = true;
  } else {
    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: who } = await sb.auth.getUser(jwt);
    const uid = who?.user?.id;
    allowed = uid === OWNER;
    if (!allowed && uid) {
      const { data: m } = await sb.from("crm_members").select("owner_id").eq("user_id", uid).maybeSingle();
      allowed = m?.owner_id === OWNER;
    }
  }
  if (!allowed) return rep(403, { ok: false, error: "forbidden" });

  let body: Record<string, any> = {};
  try { body = JSON.parse((await req.text()).slice(0, 20000) || "{}"); } catch { return rep(400, { ok: false, error: "payload" }); }
  const key = Deno.env.get("ANTHROPIC_API_KEY") || "";
  const today = new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Paris" });
  const loadCatalog = async () => {
    const { data } = await sb.from("products").select("product_id, name, categorie, actif").eq("user_id", OWNER);
    return (data || []).filter((p: any) => p.actif !== false && p.product_id && p.name).map((p: any) => ({ id: String(p.product_id), name: String(p.name) }));
  };

  // ── Tri d'un mail d'inconnu
  if (body.action === "candidat") {
    if (!fromBase) return rep(403, { ok: false, error: "forbidden" });
    const id = Number(body.id);
    const { data: c } = await sb.from("mail_candidates").select("*").eq("id", id).maybeSingle();
    if (!c || c.status !== "nouveau") return rep(200, { ok: true, ignored: "etat" });
    const wipe = { from_addr: null, from_name: null, to_addr: null, subject: null, content: null, resume: null, fiche: null };
    // Adresse déjà connue entre-temps : le mail suivra le chemin normal.
    const mail = emailOf(c.from_addr);
    if (mail) {
      const { data: known } = await sb.from("prospects").select("id").eq("user_id", OWNER).ilike("email", mail).limit(1).maybeSingle();
      if (known) { await sb.from("mail_candidates").update({ status: "ignore", note: "contact déjà connu", ...wipe, decided_at: new Date().toISOString() }).eq("id", id); return rep(200, { ok: true, status: "ignore" }); }
    }
    let status = "ignore", nature = "autre", confiance = 0, resume = "", fiche: any = null, source = "regles";
    if (key) {
      const catalog = await loadCatalog();
      const system = [
        "Tu tries les mails reçus par Martingale Paris, qui vend des chaises bistrot en rotin aux cafés, hôtels, restaurants et architectes.",
        "L'expéditeur n'est pas encore client. Tu remplis l'outil trier_mail. Tu n'inventes rien.",
        "Sont à écarter : fournisseurs, transporteurs, banques, administrations, démarchage commercial (agences, SEO, logiciels), candidatures, mails personnels, publicités.",
        "Les modèles se reconnaissent à leur couleur. N'utilise que les id du catalogue.",
      ].join("\n");
      const user = ["Catalogue (id : nom) :", ...catalog.map((p: any) => `- ${p.id} : ${p.name}`), "",
        `De : ${c.from_name || ""} <${mail}>`, `Objet : ${c.subject || ""}`, "", String(c.content || "").slice(0, 4000)].join("\n");
      const r = await askClaude(key, system, user, TRI_TOOL);
      if (r.error || !r.out) {
        await sb.from("mail_candidates").update({ status: "erreur", note: String(r.error || "réponse vide").slice(0, 200) }).eq("id", id);
        return rep(200, { ok: false, error: "api", detail: r.error });
      }
      const o = r.out;
      source = "ia";
      nature = String(o.nature || "autre");
      confiance = Math.max(0, Math.min(1, Number(o.confiance) || 0));
      resume = String(o.resume || "").slice(0, 500);
      const ids = new Set(catalog.map((p: any) => p.id));
      const f = o.fiche || {};
      fiche = {
        name: String(f.name || "").slice(0, 120), contact: String(f.contact || "").slice(0, 120), tel: String(f.tel || "").slice(0, 40),
        ville: String(f.ville || "").slice(0, 60), dept: /^\d{2,3}$/.test(String(f.dept || "")) ? String(f.dept) : "",
        qty: Math.max(0, Math.min(5000, Math.round(Number(f.qty) || 0))),
        produits: (Array.isArray(f.produits) ? f.produits : []).filter((x: any) => ids.has(String(x.id)) && Number(x.qty) >= 1).map((x: any) => ({ id: String(x.id), qty: Math.round(Number(x.qty)) })),
      };
      const client = o.demande_client === true;
      if (client && ["demande_devis", "question_produit"].includes(nature) && confiance >= 0.85) status = "fiche";
      else if (client && confiance >= 0.5) status = "a_verifier";
    } else {
      const r = triRegles(String(c.subject || ""), String(c.content || ""));
      nature = r.nature; confiance = r.confiance;
      status = r.garder ? "a_verifier" : "ignore";
      resume = r.garder ? String(c.content || "").replace(/\s+/g, " ").trim().slice(0, 300) : "";
    }
    if (status === "ignore") {
      await sb.from("mail_candidates").update({ status, nature, confiance, source, ...wipe, decided_at: new Date().toISOString() }).eq("id", id);
      return rep(200, { ok: true, status });
    }
    await sb.from("mail_candidates").update({ status: status === "fiche" ? "a_verifier" : status, nature, confiance, resume, fiche, source }).eq("id", id);
    if (status === "fiche") {
      const { data: pid, error } = await sb.rpc("crm_candidate_to_prospect", { p_id: id, p_source: source });
      if (error) return rep(200, { ok: false, error: "fiche", detail: error.message });
      return rep(200, { ok: true, status, prospect_id: pid });
    }
    return rep(200, { ok: true, status });
  }

  // ── Lecture d'un mail de client
  if (body.action === "mail") {
    if (!fromBase) return rep(403, { ok: false, error: "forbidden" });
    const { data: m } = await sb.from("messages").select("id, prospect_id, direction, canal, subject, content, sent_at, meta").eq("id", String(body.message_id || "")).maybeSingle();
    if (!m || m.direction !== "in" || !m.prospect_id) return rep(200, { ok: true, ignored: "message" });
    const { data: p } = await sb.from("prospects").select("id, name, statut, devis_demande_at").eq("id", m.prospect_id).maybeSingle();
    if (!p) return rep(200, { ok: true, ignored: "fiche" });
    const { data: docs } = await sb.from("documents").select("num, type, statut, ttc, created_at").eq("prospect_id", p.id).order("created_at", { ascending: false }).limit(5);
    let r: any = null, source = "regles";
    if (key) {
      const system = [
        "Tu lis les mails reçus par Martingale Paris (chaises bistrot en rotin, clients cafés, hôtels, restaurants).",
        "Tu dis seulement si le mail change l'état du dossier, avec l'outil lire_mail. En cas de doute, « rien ».",
        "Ne tiens compte que du message du client, pas des messages cités en dessous.",
      ].join("\n");
      const user = [
        `Dossier : ${p.name || ""} · statut actuel : ${p.statut || "Nouveau"}${p.devis_demande_at ? " · devis à préparer" : ""}`,
        `Documents : ${(docs || []).map((d: any) => `${d.num} (${d.type}, ${d.statut}, ${d.ttc} € TTC)`).join(" ; ") || "aucun"}`,
        "", `Objet : ${m.subject || ""}`, "", String(m.content || "").slice(0, 5000),
      ].join("\n");
      const a = await askClaude(key, system, user, MAIL_TOOL);
      if (a.out) { r = a.out; source = "ia"; }
    }
    if (!r) r = mailRegles(String(m.subject || ""), String(m.content || ""));
    const kind = String(r.proposition || "rien");
    const conf = Math.max(0, Math.min(1, Number(r.confiance) || 0));
    if (!["gagne", "perdu", "devis", "attente"].includes(kind) || conf < 0.55) return rep(200, { ok: true, proposition: "rien" });
    // Rien à proposer si le dossier y est déjà.
    const already = (kind === "gagne" && p.statut === "Gagné") || (kind === "perdu" && p.statut === "Perdu")
      || (kind === "attente" && p.statut === "En attente chantier") || (kind === "devis" && !!p.devis_demande_at);
    if (already) return rep(200, { ok: true, proposition: "deja" });
    // Une seule proposition ouverte par dossier : la plus récente remplace l'ancienne.
    await sb.from("crm_suggestions").update({ status: "ignore", decided_at: new Date().toISOString() }).eq("prospect_id", p.id).eq("status", "propose");
    const extrait = String(m.content || "").split(/\n\s*\n/)[0].replace(/\s+/g, " ").trim().slice(0, 220);
    const { error } = await sb.from("crm_suggestions").insert({
      user_id: OWNER, prospect_id: p.id, message_id: m.id, kind, raison: String(r.raison || "").slice(0, 160), extrait, confiance: conf, source,
    });
    if (error && (error as any).code !== "23505") return rep(200, { ok: false, error: "suggestion", detail: error.message });
    return rep(200, { ok: true, proposition: kind, source });
  }

  if (body.action !== "appel") return rep(400, { ok: false, error: "action" });
  if (!key) return rep(200, { ok: false, error: "not_configured" });

  const summary = String(body.summary || "").trim().slice(0, 4000);
  if (!summary) return rep(400, { ok: false, error: "vide" });
  const catalog = (Array.isArray(body.catalog) ? body.catalog : []).slice(0, 60)
    .map((p: any) => ({ id: String(p.id || ""), name: String(p.name || "") })).filter((p: any) => p.id && p.name);
  const fiche = body.fiche || {};
  const todayCall = String(body.today || today);

  const system = [
    "Tu aides Martingale Paris, qui vend des chaises bistrot en rotin aux cafés, hôtels et restaurants.",
    "On te donne le résumé d'un appel écrit vite par le gérant, et ce que la fiche client contient déjà.",
    "Tu remplis l'outil classer_appel. Tu n'inventes rien : un champ inconnu reste vide ou à 0.",
    "Les modèles se reconnaissent à leur couleur (« kaki » = Kaki Botanique, « bleues » = Bleu Atelier...). N'utilise que les id du catalogue.",
    "Un prénom, une enseigne ou une ville qui ressemble à une couleur n'est pas un modèle.",
    "Le mobilier se vend lentement : un projet qui traîne ou qui est reporté est « attente », jamais « sans_suite ».",
    `Nous sommes le ${todayCall} (${body.weekday || ""}), à Paris.`,
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
  const date = /^\d{4}-\d{2}-\d{2}$/.test(String(out.rappel_date || "")) && String(out.rappel_date) >= todayCall ? String(out.rappel_date) : "";
  const result = {
    suite: ["devis", "rappel", "attente", "sans_suite", "contacte"].includes(out.suite) ? out.suite : "contacte",
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
