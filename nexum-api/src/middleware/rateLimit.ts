import type { Request, Response, NextFunction } from 'express'

const windowMs = 60_000 // 1 minute
const maxRequests = 100
const hits = new Map<string, { count: number; resetAt: number }>()

export function rateLimitMiddleware(req: Request, res: Response, next: NextFunction) {
  const key = req.ip ?? 'unknown'
  const now = Date.now()
  const entry = hits.get(key)

  if (!entry || now > entry.resetAt) {
    hits.set(key, { count: 1, resetAt: now + windowMs })
    return next()
  }

  entry.count++
  if (entry.count > maxRequests) {
    return res.status(429).json({ error: 'Too many requests' })
  }

  next()
}

// __NEXUM_RATELIMIT_STRICT__ (phase7) targeted limiters for auth + txn
//
// The app-wide rateLimitMiddleware above is a blunt 100/min/IP guard - fine as
// a floor, too loose for the endpoints that actually matter. These factories add
// TIGHT, purpose-built limits:
//
//   * auth endpoints (login, OTP, session, password reset): low per-IP limits to
//     blunt brute-force and credential-stuffing.
//   * txn endpoints (wallet transfers/contract calls): per-ACCOUNT limits so a
//     runaway or malicious client can't spam money-moving calls - and one
//     account's abuse never rate-limits everyone sharing an IP (NAT/mobile).
//
// Same in-memory store approach as the existing limiter (single-instance; if the
// API is ever horizontally scaled, move this to a shared store like Redis - see
// note below). Limits are env-tunable so they can be tightened without a deploy.


type KeyBy = 'ip' | 'account'

interface LimiterOpts {
  windowMs: number
  max:      number
  keyBy:    KeyBy
  name:     string   // for the 429 body + logging, e.g. 'auth' | 'txn'
}

/*
  Build a limiter middleware. Each limiter keeps its OWN bucket map, so limits
  don't bleed across endpoints (the login bucket is separate from the txn one).
*/
export function createRateLimiter(opts: LimiterOpts) {
  const buckets = new Map<string, { count: number; resetAt: number }>()

  // Opportunistic cleanup so the map can't grow unbounded from one-off IPs.
  let lastSweep = Date.now()
  function sweep(now: number) {
    if (now - lastSweep < opts.windowMs) return
    lastSweep = now
    for (const [k, v] of buckets) if (now > v.resetAt) buckets.delete(k)
  }

  return function (req: Request, res: Response, next: NextFunction) {
    const now = Date.now()
    sweep(now)

    let id: string
    if (opts.keyBy === 'account') {
      const acct = (req as any).account
      // If somehow unauthenticated (shouldn't happen behind requireAccount),
      // fall back to IP so we still limit rather than fail open.
      id = acct?.id ? `acct:${acct.id}` : `ip:${req.ip ?? 'unknown'}`
    } else {
      id = `ip:${req.ip ?? 'unknown'}`
    }
    const key = `${opts.name}:${id}`

    const entry = buckets.get(key)
    if (!entry || now > entry.resetAt) {
      buckets.set(key, { count: 1, resetAt: now + opts.windowMs })
      return next()
    }
    entry.count++
    if (entry.count > opts.max) {
      const retryAfter = Math.ceil((entry.resetAt - now) / 1000)
      res.setHeader('Retry-After', String(retryAfter))
      return res.status(429).json({
        error: 'Too many requests. Please slow down and try again shortly.',
        code:  `rate_limited_${opts.name}`,
        retryAfterSeconds: retryAfter,
      })
    }
    next()
  }
}

const int = (v: string | undefined, d: number) => {
  const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d
}

/*
  AUTH limiter: strict, per IP. Defaults to 10 attempts/minute - enough for a
  fumbling human, far below what a brute-force script needs. Tune with
  RATE_LIMIT_AUTH_MAX / RATE_LIMIT_AUTH_WINDOW_MS.
*/
export const authRateLimiter = createRateLimiter({
  name:     'auth',
  keyBy:    'ip',
  windowMs: int(process.env.RATE_LIMIT_AUTH_WINDOW_MS, 60_000),
  max:      int(process.env.RATE_LIMIT_AUTH_MAX, 10),
})

/*
  TXN limiter: per account. Defaults to 20 money-moving calls/minute per user -
  generous for real use, tight enough to stop a spam loop. Tune with
  RATE_LIMIT_TXN_MAX / RATE_LIMIT_TXN_WINDOW_MS.
*/
export const txnRateLimiter = createRateLimiter({
  name:     'txn',
  keyBy:    'account',
  windowMs: int(process.env.RATE_LIMIT_TXN_WINDOW_MS, 60_000),
  max:      int(process.env.RATE_LIMIT_TXN_MAX, 20),
})
