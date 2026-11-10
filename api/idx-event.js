// CRM-001 Lead event intake.
// What it does: the IDX Broker page script sends one website action here
// (viewed / saved_home / showing_request ...). This passes it to the database's
// front door, which finds or creates the lead, saves the event and flags hot leads.
// In:  { email, first_name, last_name, phone, idx_lead_id, kind, mls_number, address, price, at, source, source_event_id }
// Out: { ok, contact_id, is_hot, hot_reason }  or  { ok:false, error }

const ALLOWED_KINDS = ["viewed", "saved_home", "saved_search", "showing_request", "registered"];

export default async function handler(req, res) {
  // Let the IDX Broker site call us from the browser
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") return res.status(405).json({ ok: false, error: "POST only" });

  // The page sends plain text (so browsers don't block it); turn it back into data
  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = null; } }
  if (!body || !body.email || !ALLOWED_KINDS.includes(body.kind)) {
    return res.status(400).json({ ok: false, error: "needs email and a known kind" });
  }

  // Keep only the fields the database expects
  const payload = {
    email: String(body.email).slice(0, 200),
    first_name: body.first_name ?? null, last_name: body.last_name ?? null, phone: body.phone ?? null,
    idx_lead_id: body.idx_lead_id ?? null, kind: body.kind,
    mls_number: body.mls_number ?? null, address: body.address ?? null, price: body.price ?? null,
    at: body.at ?? null, source: body.source ?? "Blue Ribbon Homes", source_event_id: body.source_event_id ?? null,
  };

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: "Supabase not connected" });

  // Try up to 3 times; nothing fails silently
  let lastError = "";
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const r = await fetch(`${url}/rest/v1/rpc/ingest_idx_event`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p: payload }),
      });
      const out = await r.json();
      if (r.ok && out && out.ok) return res.status(200).json(out);
      lastError = (out && (out.error || out.message)) || `HTTP ${r.status}`;
      if (r.status < 500) break;                        // bad data won't fix itself on retry
    } catch (e) { lastError = e.message; }
    await new Promise(r => setTimeout(r, 300 * attempt)); // short pause before retrying
  }

  // Alert: shows in Vercel logs now; wired to Tracy's error email bot next
  console.error("CRM-001 failed", { email: payload.email, kind: payload.kind, error: lastError });
  return res.status(502).json({ ok: false, error: lastError });
}
