export default function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({
    url: process.env.SUPABASE_URL,
    key: process.env.SUPABASE_ANON_KEY,
    bmc: process.env.BMC_PAGE
  });
}
