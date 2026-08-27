import { describe, it, expect, vi } from 'vitest'
import { createRateLimiter } from '../src/middleware/rateLimit'

// ============================================================================
// Strict rate limiter (Phase 7 Hardening).
//
// These guard auth (brute-force) and txn (money-moving spam), so the tests pin
// the behaviours that matter: allows up to the limit, blocks past it with 429 +
// Retry-After, keys are isolated (one IP/account can't exhaust another's
// budget), the window resets, and account-keying falls back to IP when there is
// no authenticated account rather than failing open.
// ============================================================================

function mockReqRes(over: Partial<any> = {}) {
  const req: any = { ip: '1.2.3.4', ...over }
  const res: any = {
    statusCode: 200,
    headers: {} as Record<string, string>,
    setHeader(k: string, v: string) { this.headers[k] = v },
    status(c: number) { this.statusCode = c; return this },
    json(b: any) { this.body = b; return this },
  }
  return { req, res }
}

describe('createRateLimiter', () => {
  it('allows requests up to the max, then blocks with 429 + Retry-After', () => {
    const limiter = createRateLimiter({ name: 'test', keyBy: 'ip', windowMs: 60_000, max: 3 })
    let passed = 0
    for (let i = 0; i < 3; i++) {
      const { req, res } = mockReqRes()
      limiter(req, res, () => { passed++ })
    }
    expect(passed).toBe(3)

    const { req, res } = mockReqRes()
    let blockedNext = false
    limiter(req, res, () => { blockedNext = true })
    expect(blockedNext).toBe(false)
    expect(res.statusCode).toBe(429)
    expect(res.body.code).toBe('rate_limited_test')
    expect(res.headers['Retry-After']).toBeTruthy()
  })

  it('isolates buckets across different IPs', () => {
    const limiter = createRateLimiter({ name: 'iso', keyBy: 'ip', windowMs: 60_000, max: 1 })
    const a = mockReqRes({ ip: '10.0.0.1' })
    const b = mockReqRes({ ip: '10.0.0.2' })
    let aPass = false, bPass = false
    limiter(a.req, a.res, () => { aPass = true })
    limiter(b.req, b.res, () => { bPass = true })
    // Each IP gets its own budget of 1.
    expect(aPass).toBe(true)
    expect(bPass).toBe(true)
    // A's second request is blocked, B is unaffected.
    const a2 = mockReqRes({ ip: '10.0.0.1' })
    let a2Pass = false
    limiter(a2.req, a2.res, () => { a2Pass = true })
    expect(a2Pass).toBe(false)
    expect(a2.res.statusCode).toBe(429)
  })

  it('keys by account when keyBy=account, so one user cannot limit another', () => {
    const limiter = createRateLimiter({ name: 'acct', keyBy: 'account', windowMs: 60_000, max: 1 })
    const u1 = mockReqRes({ account: { id: 'user-1' }, ip: 'shared-ip' })
    const u2 = mockReqRes({ account: { id: 'user-2' }, ip: 'shared-ip' })
    let p1 = false, p2 = false
    limiter(u1.req, u1.res, () => { p1 = true })
    limiter(u2.req, u2.res, () => { p2 = true })
    // Same IP, different accounts -> both allowed (NAT/mobile safety).
    expect(p1).toBe(true)
    expect(p2).toBe(true)
    // user-1's second call is blocked, user-2 still fine.
    const u1b = mockReqRes({ account: { id: 'user-1' }, ip: 'shared-ip' })
    let p1b = false
    limiter(u1b.req, u1b.res, () => { p1b = true })
    expect(p1b).toBe(false)
  })

  it('falls back to IP when account-keyed but unauthenticated (does not fail open)', () => {
    const limiter = createRateLimiter({ name: 'fb', keyBy: 'account', windowMs: 60_000, max: 1 })
    const a = mockReqRes({ ip: '9.9.9.9' })       // no account
    const b = mockReqRes({ ip: '9.9.9.9' })       // same IP, no account
    let aPass = false, bBlocked = false
    limiter(a.req, a.res, () => { aPass = true })
    limiter(b.req, b.res, () => { bBlocked = false })
    expect(aPass).toBe(true)
    expect(b.res.statusCode).toBe(429) // limited by shared IP, not fail-open
  })

  it('resets after the window elapses', () => {
    vi.useFakeTimers()
    const limiter = createRateLimiter({ name: 'win', keyBy: 'ip', windowMs: 1_000, max: 1 })
    const a = mockReqRes({ ip: '5.5.5.5' })
    let pass1 = false
    limiter(a.req, a.res, () => { pass1 = true })
    expect(pass1).toBe(true)

    const b = mockReqRes({ ip: '5.5.5.5' })
    let pass2 = false
    limiter(b.req, b.res, () => { pass2 = true })
    expect(pass2).toBe(false) // blocked within window

    vi.advanceTimersByTime(1_100)
    const c = mockReqRes({ ip: '5.5.5.5' })
    let pass3 = false
    limiter(c.req, c.res, () => { pass3 = true })
    expect(pass3).toBe(true) // allowed again after reset
    vi.useRealTimers()
  })
})
