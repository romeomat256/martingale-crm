// Martingale : vérification d'un numéro de TVA intracommunautaire (service VIES de la Commission européenne).
// POST { vat: "BE0123456789" } -> { ok, valid, name, address }
// Gratuit, sans clé. Appelé par le CRM avant d'appliquer l'exonération de TVA UE.

function cors(origin: string | null): Record<string, string> {
  const ok = origin && (/^https:\/\/martingale-crm[a-z0-9-]*\.vercel\.app$/.test(origin) || /^http:\/\/localhost:\d+$/.test(origin));
  return {
    "Access-Control-Allow-Origin": ok ? origin! : "https://martingale-crm.vercel.app",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const rep = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return rep(405, { ok: false });

  let vat = "";
  try { vat = String((await req.json()).vat || ""); } catch { /* vide */ }
  vat = vat.toUpperCase().replace(/[^A-Z0-9]/g, "");
  const m = vat.match(/^([A-Z]{2})([A-Z0-9]{2,13})$/);
  if (!m) return rep(400, { ok: false, error: "format" });
  const country = m[1] === "GR" ? "EL" : m[1];

  try {
    const r = await fetch("https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ countryCode: country, vatNumber: m[2] }),
    });
    const j = await r.json();
    if (!r.ok || j.errorWrappers) return rep(200, { ok: false, error: "indisponible", detail: j.errorWrappers?.[0]?.error || r.status });
    const clean = (s: unknown) => (typeof s === "string" && s !== "---" ? s.replace(/\s+/g, " ").trim() : "");
    return rep(200, { ok: true, valid: !!j.valid, name: clean(j.name), address: clean(j.address), checked_at: new Date().toISOString() });
  } catch (e) {
    return rep(200, { ok: false, error: "indisponible", detail: String(e).slice(0, 200) });
  }
});
