// Martingale : stock du CRM vers Shopify.
// Quand une commande pro part (statut « Expédié » ou « Livré »), la base inscrit un mouvement dans
// shopify_stock_moves. Cette fonction envoie les mouvements en attente à Shopify, article par article.
// Shopify renvoie ensuite le nouveau niveau de stock au CRM par sa notification habituelle.
//
// Appels :
//   - par la base (pg_net) avec l'en-tête x-crm-cron, dès qu'un mouvement est inscrit, puis tous les quarts d'heure ;
//   - depuis le CRM, par un membre de l'équipe connecté.
// Clés (Supabase > Edge Functions > Secrets) : SHOPIFY_CLIENT_ID et SHOPIFY_CLIENT_SECRET, celles d'une appli
// créée dans le Dev Dashboard de Shopify, installée sur la boutique, avec les droits read_inventory et write_inventory.
// Tant qu'elles manquent, les mouvements sont laissés de côté (rien n'est rejoué par surprise le jour du branchement).

import { createClient } from "jsr:@supabase/supabase-js@2";

const FALLBACK_OWNER = "e0ea9ee1-90e8-4162-9e80-d264b7f993fb";
const SHOP = Deno.env.get("SHOPIFY_SHOP") || "kffmce-jx.myshopify.com";
const API_VERSION = "2026-10";
const MAX_TRIES = 8;

function cors(origin: string | null): Record<string, string> {
  const ok = origin && (/^https:\/\/martingale-crm[a-z0-9-]*\.vercel\.app$/.test(origin) || /^http:\/\/localhost:\d+$/.test(origin));
  return {
    "Access-Control-Allow-Origin": ok ? origin! : "https://martingale-crm.vercel.app",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

async function shopifyToken(id: string, secret: string): Promise<{ token?: string; error?: string }> {
  const res = await fetch(`https://${SHOP}/admin/oauth/access_token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: id, client_secret: secret }),
  });
  const text = await res.text();
  let body: any = null;
  try { body = JSON.parse(text); } catch { /* réponse non JSON */ }
  if (!res.ok || !body?.access_token) {
    return { error: `jeton refusé (${res.status}) : ${String(body?.error_description || body?.error || text).slice(0, 160)}` };
  }
  return { token: String(body.access_token) };
}

const MUTATION = (key: string) => `mutation MouvementCrm($input: InventoryAdjustQuantitiesInput!) {
  inventoryAdjustQuantities(input: $input) @idempotent(key: "${key}") {
    inventoryAdjustmentGroup { id }
    userErrors { field message }
  }
}`;

async function adjust(token: string, move: any, withReference: boolean): Promise<{ ok: boolean; error?: string; group?: string }> {
  const changes = (move.lines || [])
    .filter((l: any) => l && l.inventory_item_id && l.location_id && Number(l.qty) > 0)
    .map((l: any) => ({
      delta: Number(move.direction) * Math.round(Number(l.qty)),
      changeFromQuantity: null,   // pas de contrôle « quantité attendue » : on retire ce qui est parti, quel que soit le niveau lu
      inventoryItemId: `gid://shopify/InventoryItem/${l.inventory_item_id}`,
      locationId: `gid://shopify/Location/${l.location_id}`,
    }));
  if (!changes.length) return { ok: false, error: "aucune ligne exploitable" };
  const input: Record<string, unknown> = { name: "available", reason: "correction", changes };
  if (withReference) {
    input.referenceDocumentUri = `gid://martingale-crm/Commande/${encodeURIComponent(String(move.quote_num || move.order_id))}`;
  }
  const res = await fetch(`https://${SHOP}/admin/api/${API_VERSION}/graphql.json`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": token },
    body: JSON.stringify({ query: MUTATION(String(move.idem_key)), variables: { input } }),
  });
  const text = await res.text();
  let body: any = null;
  try { body = JSON.parse(text); } catch { /* réponse non JSON */ }
  if (!res.ok) return { ok: false, error: `Shopify ${res.status} : ${text.slice(0, 200)}` };
  if (body?.errors?.length) return { ok: false, error: body.errors.map((e: any) => e.message).join(" ; ").slice(0, 300) };
  const out = body?.data?.inventoryAdjustQuantities;
  const errs = out?.userErrors || [];
  if (errs.length) return { ok: false, error: errs.map((e: any) => `${(e.field || []).join(".")} ${e.message}`.trim()).join(" ; ").slice(0, 300) };
  return { ok: true, group: out?.inventoryAdjustmentGroup?.id || "" };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return rep(405, { ok: false });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Qui appelle ? La base (secret gardé dans le coffre) ou un membre de l'équipe.
  let owner: string | null = null;
  const cronSecret = req.headers.get("x-crm-cron") || "";
  if (cronSecret) {
    const { data: ok } = await sb.rpc("crm_cron_secret_ok", { p: cronSecret });
    if (ok !== true) return rep(403, { ok: false, error: "forbidden" });
    owner = FALLBACK_OWNER;
  } else {
    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: who } = await sb.auth.getUser(jwt);
    const uid = who?.user?.id;
    if (uid === FALLBACK_OWNER) owner = uid;
    else if (uid) {
      const { data: member } = await sb.from("crm_members").select("owner_id").eq("user_id", uid).maybeSingle();
      if (member?.owner_id === FALLBACK_OWNER) owner = member.owner_id;
    }
    if (!owner) return rep(403, { ok: false, error: "forbidden" });
  }

  const now = () => new Date().toISOString();
  const saveState = (value: Record<string, unknown>) =>
    sb.from("crm_sync_state").upsert({ key: "shopify_push", value: { at: now(), ...value }, updated_at: now() });

  const { data: moves, error: readErr } = await sb.from("shopify_stock_moves")
    .select("*").eq("user_id", owner).eq("status", "a_faire").order("id", { ascending: true }).limit(25);
  if (readErr) return rep(500, { ok: false, error: "lecture" });

  const clientId = Deno.env.get("SHOPIFY_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("SHOPIFY_CLIENT_SECRET") || "";
  if (!clientId || !clientSecret) {
    // Pas encore branché : on ne garde pas de mouvements en réserve, pour ne rien rejouer plus tard par surprise.
    if (moves?.length) {
      await sb.from("shopify_stock_moves")
        .update({ status: "ignore", note: "Shopify pas encore branché : stock à ajuster à la main, ou à appliquer d’ici une fois branché." })
        .in("id", moves.map((m: any) => m.id));
    }
    await saveState({ configured: false, laisses: moves?.length || 0 });
    return rep(200, { ok: false, error: "not_configured", laisses: moves?.length || 0 });
  }

  if (!moves?.length) {
    await saveState({ configured: true, ok: true, faits: 0, erreurs: 0 });
    return rep(200, { ok: true, faits: 0, erreurs: 0 });
  }

  const auth = await shopifyToken(clientId, clientSecret);
  if (!auth.token) {
    for (const m of moves) {
      const tries = (m.tries || 0) + 1;
      await sb.from("shopify_stock_moves")
        .update({ tries, note: auth.error, ...(tries >= MAX_TRIES ? { status: "erreur" } : {}) }).eq("id", m.id);
    }
    await saveState({ configured: true, ok: false, erreur: auth.error });
    return rep(200, { ok: false, error: "token", detail: auth.error });
  }

  let faits = 0, erreurs = 0;
  const details: unknown[] = [];
  for (const m of moves) {
    let r = await adjust(auth.token, m, true);
    // La référence de la commande est facultative : si Shopify la refuse, le mouvement part sans elle.
    if (!r.ok && /reference/i.test(r.error || "")) r = await adjust(auth.token, m, false);
    if (r.ok) {
      faits++;
      await sb.from("shopify_stock_moves").update({ status: "fait", done_at: now(), tries: (m.tries || 0) + 1, note: m.note && /^Retour/.test(m.note) ? m.note : null }).eq("id", m.id);
    } else {
      erreurs++;
      await sb.from("shopify_stock_moves").update({ status: "erreur", tries: (m.tries || 0) + 1, note: r.error }).eq("id", m.id);
    }
    details.push({ id: m.id, commande: m.quote_num, ok: r.ok, erreur: r.error || null });
  }
  await saveState({ configured: true, ok: erreurs === 0, faits, erreurs });
  return rep(200, { ok: erreurs === 0, faits, erreurs, details });
});
