// ROSTER-004 Monthly fee report (read-only).
// What it does: the 2nd-of-month email task opens this link with the report secret;
// the database checks the secret and returns who has / hasn't set up the Bowie + Front Royal monthly fee.
// In:  GET /api/fee-report?s=<report secret>
// Out: { ok:true, set_up:[...], failed_or_canceled:[...], not_set_up_bowie:[...], not_set_up_front_royal:[...],
//        paid_for_year_or_exempt:[...], stripe_not_on_roster:[...], checked_at }   or   { ok:false }
export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;               // project address
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;    // public key
  const secret = String(req.query.s || "").slice(0, 100);                                    // report secret from the link
  if (!url || !key) return res.status(500).json({ ok: false, error: "not connected" });
  if (!secret) return res.status(401).json({ ok: false });
  for (let i = 0; i < 3; i++) {                                                              // retry twice on a hiccup
    try {
      const r = await fetch(`${url}/rest/v1/rpc/roster_fee_report`, {
        method: "POST",
        headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_secret: secret }),
      });
      if (r.ok) { const data = await r.json(); return res.status(data.ok ? 200 : 401).json(data); }
    } catch (e) { /* try again */ }
    await new Promise(r => setTimeout(r, 500 * (i + 1)));
  }
  console.error("fee-report: database did not answer");                                     // shows in Vercel logs
  return res.status(502).json({ ok: false, error: "database did not answer" });
}
