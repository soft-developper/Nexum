import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

// ============================================================================
// Structured logger + thin Sentry capture (Phase 7 Hardening).
//
// The whole point of this module is that failures stop being lost, so the tests
// assert exactly that: every capture is logged (with no DSN), a DSN turns on an
// HTTP ship, and capture never throws - because an error reporter that can
// itself throw would defeat its own purpose inside a catch block.
// ============================================================================

describe('logger', () => {
  const savedEnv = { ...process.env }

  beforeEach(() => {
    vi.resetModules()
    delete process.env.SENTRY_DSN
    process.env.LOG_LEVEL = 'debug'
  })
  afterEach(() => {
    process.env = { ...savedEnv }
    vi.restoreAllMocks()
  })

  it('emits structured JSON with level, service and message', async () => {
    const spy = vi.spyOn(console, 'log').mockImplementation(() => {})
    const { log } = await import('../src/lib/logger')
    log.info('hello', { foo: 'bar' })
    expect(spy).toHaveBeenCalledTimes(1)
    const parsed = JSON.parse(spy.mock.calls[0][0] as string)
    expect(parsed.level).toBe('info')
    expect(parsed.service).toBe('nexum-api')
    expect(parsed.msg).toBe('hello')
    expect(parsed.foo).toBe('bar')
    expect(typeof parsed.ts).toBe('string')
  })

  it('respects LOG_LEVEL (debug suppressed when level is info)', async () => {
    process.env.LOG_LEVEL = 'info'
    const spy = vi.spyOn(console, 'log').mockImplementation(() => {})
    const { log } = await import('../src/lib/logger')
    log.debug('should be hidden')
    expect(spy).not.toHaveBeenCalled()
  })

  it('routes warn/error to stderr', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const { log } = await import('../src/lib/logger')
    log.error('boom')
    expect(errSpy).toHaveBeenCalledTimes(1)
    expect(JSON.parse(errSpy.mock.calls[0][0] as string).level).toBe('error')
  })

  it('captureException always logs the error, even with no DSN', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchSpy = vi.fn()
    vi.stubGlobal('fetch', fetchSpy)
    const { captureException } = await import('../src/lib/logger')
    captureException(new Error('kaboom'), { batchId: 'B1' })
    expect(errSpy).toHaveBeenCalled()
    const parsed = JSON.parse(errSpy.mock.calls[0][0] as string)
    expect(parsed.msg).toBe('kaboom')
    expect(parsed.batchId).toBe('B1')
    expect(parsed.stack).toContain('Error')
    // No DSN -> no HTTP ship
    expect(fetchSpy).not.toHaveBeenCalled()
    vi.unstubAllGlobals()
  })

  it('captureException ships to Sentry when SENTRY_DSN is set', async () => {
    process.env.SENTRY_DSN = 'https://abc123@o1.ingest.sentry.io/456'
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchSpy = vi.fn(async () => ({ ok: true }))
    vi.stubGlobal('fetch', fetchSpy as any)
    const { captureException } = await import('../src/lib/logger')
    captureException(new Error('ship me'))
    // fetch is fire-and-forget; give the microtask a tick
    await new Promise(r => setTimeout(r, 0))
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, opts] = fetchSpy.mock.calls[0]
    expect(String(url)).toBe('https://o1.ingest.sentry.io/api/456/store/')
    expect((opts as any).headers['X-Sentry-Auth']).toContain('sentry_key=abc123')
    vi.unstubAllGlobals()
  })

  it('captureException never throws, even on a broken DSN or bad fetch', async () => {
    process.env.SENTRY_DSN = 'not-a-valid-dsn'
    vi.spyOn(console, 'error').mockImplementation(() => {})
    vi.stubGlobal('fetch', () => { throw new Error('network exploded') })
    const { captureException } = await import('../src/lib/logger')
    expect(() => captureException(new Error('x'))).not.toThrow()
    vi.unstubAllGlobals()
  })

  it('accepts a non-Error value without throwing', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const { captureException } = await import('../src/lib/logger')
    expect(() => captureException('just a string')).not.toThrow()
  })
})
