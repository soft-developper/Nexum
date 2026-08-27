import { describe, it, expect, vi, afterEach } from 'vitest'
import {
  maxFeeFor, toUnits, fromUnits, fastTransferSupported, etaSeconds,
  getTransferQuote, getBothQuotes, fetchFeeTable,
} from '@/lib/cctp-client'

// ============================================================================
// CCTP money-math unit tests (Phase 7 Hardening, part 1).
//
// This is the highest-value coverage gap in the whole project: the fee math
// moves real USDC, and it already shipped one bug that no test would have
// caught - BigInt(fractionalBps) throwing, which silently killed the quote on
// every Fast-capable chain (Base/Arbitrum/OP/Unichain). The `fractional bps`
// block below is a direct regression test for exactly that failure, so it can
// never come back unnoticed.
//
// Everything here is pure or fetch-stubbed - no network, no wallet, no funds.
// ============================================================================

const USDC = (n: number) => toUnits(n) // readable helper: USDC(10) === 10_000000n

// Build a fake Iris/proxy fee response. minimumFee is in basis points and MAY
// be fractional, exactly as Circle returns it.
function stubFees(rows: Array<{ finalityThreshold: number; minimumFee: number }>) {
  vi.stubGlobal('fetch', vi.fn(async () => ({
    ok: true,
    json: async () => rows,
  })) as any)
}
function stubFetchFailure() {
  vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('network down') }) as any)
}
function stub404() {
  vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404, json: async () => ({}) })) as any)
}

afterEach(() => { vi.unstubAllGlobals() })

// ── toUnits / fromUnits round-trip ──────────────────────────────────────────
describe('toUnits / fromUnits', () => {
  it('converts whole and fractional USDC to 6-decimal base units exactly', () => {
    expect(toUnits(1)).toBe(BigInt(1000000))
    expect(toUnits(10.5)).toBe(BigInt(10500000))
    expect(toUnits(0.000001)).toBe(BigInt(1))          // one base unit
    expect(toUnits(0)).toBe(BigInt(0))
  })

  it('does not lose precision on values that float math would round', () => {
    // 0.1 + 0.2 famously != 0.3 in float; string-based toUnits must be exact.
    expect(toUnits(0.3)).toBe(BigInt(300000))
    expect(toUnits(123.456789)).toBe(BigInt(123456789)) // 6dp, no 7th digit
  })

  it('round-trips through fromUnits', () => {
    for (const v of [0, 1, 10.5, 0.000001, 999.999999]) {
      expect(fromUnits(toUnits(v))).toBe(v)
    }
  })
})

// ── maxFeeFor: Circle's exact formula, decimal-safe ─────────────────────────
describe('maxFeeFor', () => {
  it('is zero for a free (0 bps) transfer', () => {
    expect(maxFeeFor(USDC(100), 0)).toBe(BigInt(0))
    expect(maxFeeFor(USDC(100), -1)).toBe(BigInt(0)) // guard: never negative
  })

  it('applies amount * round(bps*100)/1e6 with a 20% buffer by default', () => {
    // 100 USDC @ 1 bps: protocolFee = 100e6 * 100 / 1e6 = 10000 units (0.01 USDC)
    // buffered = 10000 * 120/100 = 12000
    expect(maxFeeFor(USDC(100), 1)).toBe(BigInt(12000))
  })

  it('handles FRACTIONAL bps without throwing (the class of the shipped bug)', () => {
    // 100 USDC @ 0.5 bps: 100e6 * round(50)/1e6 = 5000; *1.2 = 6000
    expect(() => maxFeeFor(USDC(100), 0.5)).not.toThrow()
    expect(maxFeeFor(USDC(100), 0.5)).toBe(BigInt(6000))
    // @ 1.4 bps (Circle's documented max): 100e6 * 140 /1e6 = 14000; *1.2 = 16800
    expect(maxFeeFor(USDC(100), 1.4)).toBe(BigInt(16800))
  })

  it('respects a custom buffer', () => {
    // 100 USDC @ 1 bps, 0% buffer -> exactly the protocol fee, 10000
    expect(maxFeeFor(USDC(100), 1, 0)).toBe(BigInt(10000))
  })

  it('floors at 1 unit when the math rounds to zero but a fee is owed', () => {
    // A tiny amount with a tiny bps rounds toward 0, but Fast requires fee > 0.
    expect(maxFeeFor(BigInt(1), 0.01)).toBe(BigInt(1))
  })
})

// ── static chain capability ─────────────────────────────────────────────────
describe('fastTransferSupported', () => {
  it('is true only for chains Circle offers Fast as a source', () => {
    for (const k of ['ethereum', 'base', 'arbitrum', 'optimism', 'unichain']) {
      expect(fastTransferSupported(k)).toBe(true)
    }
  })
  it('is false where standard attestation is already fast', () => {
    for (const k of ['arc', 'avalanche', 'polygon', 'monad']) {
      expect(fastTransferSupported(k)).toBe(false)
    }
  })
  it('is false for an unknown chain key', () => {
    expect(fastTransferSupported('nope')).toBe(false)
  })
})

describe('etaSeconds', () => {
  it('gives a fast ETA on fast-capable chains and a slow one on standard', () => {
    expect(etaSeconds('base', 'fast')).toBeLessThan(etaSeconds('base', 'standard'))
  })
  it('reports near-instant standard finality for Arc', () => {
    expect(etaSeconds('arc', 'standard')).toBeLessThanOrEqual(5)
  })
})

// ── fetchFeeTable: normalises + degrades safely ─────────────────────────────
describe('fetchFeeTable', () => {
  it('normalises the fee rows and drops entries without a threshold', async () => {
    stubFees([
      { finalityThreshold: 1000, minimumFee: 0.5 },
      { finalityThreshold: 2000, minimumFee: 0 },
      { finalityThreshold: 0,    minimumFee: 9 }, // junk, must be filtered
    ])
    const t = await fetchFeeTable('unused', 6, 0)
    expect(t).toEqual([
      { finalityThreshold: 1000, minimumFeeBps: 0.5 },
      { finalityThreshold: 2000, minimumFeeBps: 0 },
    ])
  })

  it('returns [] on a network failure instead of throwing', async () => {
    stubFetchFailure()
    await expect(fetchFeeTable('unused', 6, 0)).resolves.toEqual([])
  })

  it('returns [] on a 404 (route/endpoint missing)', async () => {
    stub404()
    await expect(fetchFeeTable('unused', 6, 0)).resolves.toEqual([])
  })
})

// ── getTransferQuote: the whole path, including the regression ───────────────
describe('getTransferQuote', () => {
  const base = {
    irisBase: 'unused', fromKey: 'base', fromDomain: 6, toDomain: 0,
    amountUnits: USDC(100),
  }

  it('quotes a FAST transfer with a fractional-bps fee (regression)', async () => {
    stubFees([{ finalityThreshold: 1000, minimumFee: 0.5 }])
    const q = await getTransferQuote({ ...base, mode: 'fast' })
    expect(q.mode).toBe('fast')
    expect(q.feeBps).toBe(0.5)
    // feeUnits = 100e6 * round(0.5*100)/1e6 = 100e6 * 50 /1e6 = 5000
    expect(q.feeUnits).toBe(BigInt(5000))
    expect(q.receiveUnits).toBe(USDC(100) - BigInt(5000))
    expect(q.maxFeeUnits).toBe(BigInt(6000)) // 5000 * 1.2
    expect(q.degraded).toBe(false)
  })

  it('treats STANDARD as free', async () => {
    stubFees([{ finalityThreshold: 2000, minimumFee: 0 }])
    const q = await getTransferQuote({ ...base, mode: 'standard' })
    expect(q.feeBps).toBe(0)
    expect(q.feeUnits).toBe(BigInt(0))
    expect(q.receiveUnits).toBe(USDC(100))
    expect(q.maxFeeUnits).toBe(BigInt(0))
  })

  it('degrades Fast to Standard on a source chain that cannot do Fast', async () => {
    stubFees([{ finalityThreshold: 2000, minimumFee: 0 }])
    const q = await getTransferQuote({
      ...base, fromKey: 'arc', mode: 'fast',
    })
    expect(q.mode).toBe('standard') // silently downgraded
    expect(q.degraded).toBe(true)
    expect(q.fastSupported).toBe(false)
  })

  it('never makes the recipient receive more than was sent', async () => {
    stubFees([{ finalityThreshold: 1000, minimumFee: 1.4 }])
    const q = await getTransferQuote({ ...base, mode: 'fast' })
    expect(q.receiveUnits + q.feeUnits).toBe(base.amountUnits)
  })

  it('still returns a usable quote when the fee API is down (Standard free)', async () => {
    stubFetchFailure()
    const q = await getTransferQuote({ ...base, mode: 'standard' })
    expect(q.feeUnits).toBe(BigInt(0))
    expect(q.receiveUnits).toBe(USDC(100))
  })
})

// ── getBothQuotes: powers the UI toggle ─────────────────────────────────────
describe('getBothQuotes', () => {
  it('returns both modes for a fast-capable chain, sharing one fee fetch', async () => {
    const spy = vi.fn(async () => ({
      ok: true,
      json: async () => [
        { finalityThreshold: 1000, minimumFee: 0.5 },
        { finalityThreshold: 2000, minimumFee: 0 },
      ],
    }))
    vi.stubGlobal('fetch', spy as any)

    const { fast, standard } = await getBothQuotes({
      irisBase: 'unused', fromKey: 'base', fromDomain: 6, toDomain: 0,
      amountUnits: USDC(100),
    })
    expect(fast).not.toBeNull()
    expect(fast!.feeUnits).toBe(BigInt(5000))
    expect(standard.feeUnits).toBe(BigInt(0))
    expect(spy).toHaveBeenCalledTimes(1) // one shared fee-table fetch
  })

  it('returns fast=null for a chain that cannot source Fast', async () => {
    stubFees([{ finalityThreshold: 2000, minimumFee: 0 }])
    const { fast, standard } = await getBothQuotes({
      irisBase: 'unused', fromKey: 'polygon', fromDomain: 7, toDomain: 0,
      amountUnits: USDC(100),
    })
    expect(fast).toBeNull()
    expect(standard).not.toBeNull()
  })

  it('still yields a Fast quote when the fee number is missing (fee shows Free)', async () => {
    // The bug symptom was Fast vanishing; availability must NOT depend on the
    // fee fetch. With an empty table, Fast is still offered at 0 fee.
    stubFees([])
    const { fast } = await getBothQuotes({
      irisBase: 'unused', fromKey: 'base', fromDomain: 6, toDomain: 0,
      amountUnits: USDC(100),
    })
    expect(fast).not.toBeNull()
    expect(fast!.feeUnits).toBe(BigInt(0))
  })
})
