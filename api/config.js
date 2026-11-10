// Hands My Desk the Supabase address and PUBLIC key.
// The public key is safe in a browser: the database's who-sees-what rules do the protecting.
// Both values are filled in by the Supabase–Vercel connection, so nobody copies keys by hand.
export default function handler(req, res) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;           // project address
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY; // public key
  if (!url || !anonKey) return res.status(500).json({ ok: false, error: "Supabase not connected to this Vercel project" });
  res.setHeader("Cache-Control", "no-store");
  res.status(200).json({ ok: true, url, anonKey });
}
