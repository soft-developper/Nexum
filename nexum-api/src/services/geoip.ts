// __NEXUM_GEOIP_RESOLVER__
// Resolve an approximate CITY from a client IP, for the "devices & sessions"
// list. Best-effort only: every failure path returns null and NEVER throws, so
// a slow or down geo provider can never block or break login.
//
// Called once at login (createSession stores the result), not per page view.
// Private/loopback IPs and missing IPs resolve to null.

const LOOKUP_TIMEOUT_MS = 2500

// ip-api.com free endpoint: no key, returns JSON, city field. HTTP only on the
// free tier. If it is unreachable (e.g. from a locked-down sandbox) we simply
// get null and move on.
const GEOIP_URL = (ip: string) =>
  `http://ip-api.com/json/${encodeURIComponent(ip)}?fields=status,city,country`

function isPrivateOrLocal(ip: string): boolean {
  if (!ip) return true
  const s = ip.trim()
  if (s === '::1' || s === '127.0.0.1' || s.startsWith('::ffff:127.')) return true
  if (s === 'localhost') return true
  if (s.startsWith('10.') || s.startsWith('192.168.')) return true
  // 172.16.0.0 - 172.31.255.255
  const m = s.match(/^172\.(\d+)\./)
  if (m) { const o = Number(m[1]); if (o >= 16 && o <= 31) return true }
  // fc00::/7 unique-local IPv6
  if (/^f[cd][0-9a-f]{2}:/i.test(s)) return true
  return false
}

/**
 * Return "City, Country" (or just "City", or null). Normalises an IPv4-mapped
 * IPv6 like ::ffff:1.2.3.4 down to the v4 form for the lookup.
 */
export async function cityFromIp(ip: string | null | undefined): Promise<string | null> {
  try {
    if (!ip) return null
    let addr = String(ip).trim()
    const mapped = addr.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i)
    if (mapped) addr = mapped[1]
    if (isPrivateOrLocal(addr)) return null

    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), LOOKUP_TIMEOUT_MS)
    let data: any
    try {
      const res = await fetch(GEOIP_URL(addr), { signal: ctrl.signal })
      if (!res.ok) return null
      data = await res.json()
    } finally {
      clearTimeout(timer)
    }

    if (!data || data.status !== 'success') return null
    const city    = typeof data.city === 'string' ? data.city.trim() : ''
    const country = typeof data.country === 'string' ? data.country.trim() : ''
    if (city && country) return `${city}, ${country}`
    if (city)    return city
    if (country) return country
    return null
  } catch {
    // Timeout, abort, network error, bad JSON - all non-fatal.
    return null
  }
}
