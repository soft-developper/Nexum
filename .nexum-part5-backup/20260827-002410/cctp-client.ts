// ============================================================
// CCTP V2 client -- ABIs, fee lookup and attestation polling.
//
// STAGE 3a. Everything here was written against Circle's official technical
// guide, NOT from memory, because several details are easy to get wrong and
// expensive when you do:
//
//   * V2's depositForBurn takes SEVEN parameters, not V1's four. Many
//     third-party snippets still show the V1 shape. Using it would not compile
//     against the real contract.
//
//   * maxFee: 0 REVERTS. Circle: "If maxFee is less than the minimum Standard
//     Transfer fee, the burn reverts onchain." So we fetch the current fee from
//     the API and derive maxFee from it. The fee is returned in BASIS POINTS and
//     must be multiplied by the amount.
//
//   * Attestations are fetched by TRANSACTION HASH via GET /v2/messages, not by
//     a hash you compute yourself.
//
//   * Only two finality thresholds exist: 1000 (Confirmed/Fast) and 2000
//     (Finalized/Standard). Anything below 1000 is treated as 1000, anything
//     above as 2000.
//
//   * Iris rate limit is 40 req/s, and breaching it blocks you for FIVE
//     MINUTES. Polling is therefore deliberately slow.
//
//   * A burn expires after 24h, BUT POST /v2/reattest/{nonce} revives it with
//     no deadline. This is why a "stranded" transfer is recoverable rather than
//     lost.
// ============================================================

export const FINALITY = {
  CONFIRMED: 1000,   // Fast, where the chain supports it
  FINALIZED: 2000,   // Standard
} as const

// ── ABIs (only the pieces we call) ─────────────────────────
export const TOKEN_MESSENGER_V2_ABI = [
  {
    type: 'function',
    name: 'depositForBurn',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'amount',               type: 'uint256' },
      { name: 'destinationDomain',    type: 'uint32'  },
      { name: 'mintRecipient',        type: 'bytes32' },
      { name: 'burnToken',            type: 'address' },
      { name: 'destinationCaller',    type: 'bytes32' },
      { name: 'maxFee',               type: 'uint256' },
      { name: 'minFinalityThreshold', type: 'uint32'  },
    ],
    outputs: [],
  },
] as const

export const MESSAGE_TRANSMITTER_V2_ABI = [
  {
    type: 'function',
    name: 'receiveMessage',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'message',     type: 'bytes' },
      { name: 'attestation', type: 'bytes' },
    ],
    outputs: [{ name: 'success', type: 'bool' }],
  },
] as const

export const ERC20_ABI = [
  {
    type: 'function', name: 'approve', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'allowance', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

// ── Fees ───────────────────────────────────────────────────
export interface BurnFee {
  minimumFeeBps: number      // basis points, from the API
  maxFeeUnits:   bigint      // what to pass as maxFee (in token units)
  isFast:        boolean
}

/*
  Fetch the current fee for a route and turn it into a maxFee we can pass.

  Circle returns `minimumFee` in BASIS POINTS. maxFee = amount * bps / 10_000.
  We add a safety margin because the fee can move between quoting and burning,
  and an under-quoted maxFee makes the burn REVERT.
*/
export async function getBurnFee(
  irisBase: string, fromDomain: number, toDomain: number,
  amountUnits: bigint, marginPct = 50,
): Promise<BurnFee> {
  const url = `${irisBase}/v2/burn/USDC/fees/${fromDomain}/${toDomain}`
  try {
    const res = await fetch(url)
    if (!res.ok) throw new Error(`fee lookup ${res.status}`)
    const data: any = await res.json()

    // The response carries both fast and standard entries; take the standard
    // (finality 2000) minimum unless a fast one is clearly cheaper.
    const entries: any[] = Array.isArray(data) ? data : (data?.data ?? [data])
    const standard = entries.find(e => Number(e?.finalityThreshold) === 2000) ?? entries[0]
    const bps = Number(standard?.minimumFee ?? 0)

    /*
      maxFee = amount * bps / 10_000, plus a PROPORTIONAL safety margin.

      The margin is a PERCENTAGE OF THE FEE, not extra basis points on the
      amount. An earlier version added 100 bps to the rate, which on a 1 bps
      fee meant authorising ~1% of the transfer as fees, a hundred times more
      than necessary. maxFee is a ceiling the user is agreeing to pay, so it
      must be tight.
    */
    const base   = (amountUnits * BigInt(bps)) / BigInt(10000)
    const withMargin = base + (base * BigInt(marginPct)) / BigInt(100)

    return {
      minimumFeeBps: bps,
      // Never 0 a zero maxFee reverts the burn. Floor at 1 unit.
      maxFeeUnits: withMargin > BigInt(0) ? withMargin : BigInt(1),
      isFast: false,
    }
  } catch {
    /*
      If the fee API is unreachable we do NOT guess zero (that reverts). Use a
      conservative 2 bps, which sits above the published minimums while still
      being a small fraction of the transfer.
    */
    const fallback = (amountUnits * BigInt(2)) / BigInt(10000)
    return { minimumFeeBps: 2, maxFeeUnits: fallback > BigInt(0) ? fallback : BigInt(1), isFast: false }
  }
}

// ── Attestation ────────────────────────────────────────────
export interface AttestationResult {
  status:      'pending' | 'complete' | 'not_found'
  message?:    string      // the raw message bytes, needed for receiveMessage
  attestation?: string     // Circle's signature
  nonce?:      string
  eventNonce?: string
  // __NEXUM_ATTEST_EXPIRY__ (part4) block after which this attestation can no
  // longer mint; past it, call reattest() for a fresh one. Empty when unknown.
  expirationBlock?: string
}

/*
  Fetch the attestation for a burn, keyed by the SOURCE transaction hash.

  Note the domain in the path is the SOURCE domain, a common mix-up is passing
  the destination.
*/
export async function fetchAttestation(
  irisBase: string, sourceDomain: number, burnTxHash: string,
): Promise<AttestationResult> {
  const url = `${irisBase}/v2/messages/${sourceDomain}?transactionHash=${burnTxHash}`
  const res = await fetch(url)

  if (res.status === 404) return { status: 'not_found' }
  if (res.status === 429) {
    // Breaching Iris's 40 req/s limit blocks us for five minutes, so treat this
    // as "pending" and back off rather than hammering it further.
    return { status: 'pending' }
  }
  if (!res.ok) return { status: 'pending' }

  const data: any = await res.json().catch(() => ({}))
  const msg = data?.messages?.[0]
  if (!msg) return { status: 'not_found' }

  if (msg.status === 'complete' && msg.attestation && msg.message) {
    return {
      status: 'complete',
      message: msg.message,
      attestation: msg.attestation,
      nonce: msg.eventNonce ?? msg.nonce,
      eventNonce: msg.eventNonce,
      expirationBlock: msg.decodedMessage?.expirationBlock ?? msg.expirationBlock,
    }
  }
  return { status: 'pending', nonce: msg.eventNonce ?? msg.nonce }
}

/*
  Revive an expired burn. Circle: a burn's attestation expires after ~24h, but
  reattest can be called AT ANY TIME with no deadline. This is the mechanism
  that makes a long-stranded transfer recoverable.
*/
export async function reattest(irisBase: string, nonce: string): Promise<boolean> {
  try {
    const res = await fetch(`${irisBase}/v2/reattest/${nonce}`, { method: 'POST' })
    return res.ok
  } catch { return false }
}

// USDC is 6 decimals on every CCTP chain (including Arc's ERC-20 interface).
export const USDC_DECIMALS = 6

export function toUnits(amount: number, decimals = USDC_DECIMALS): bigint {
  // Avoid float rounding: work on the string form.
  const [whole, frac = ''] = String(amount).split('.')
  const padded = (frac + '0'.repeat(decimals)).slice(0, decimals)
  // Avoid ** on bigint (needs a higher TS target): build the multiplier by
  // string, which is exact for any decimal count.
  const mult = BigInt('1' + '0'.repeat(decimals))
  return BigInt(whole || '0') * mult + BigInt(padded || '0')
}

export function fromUnits(units: bigint, decimals = USDC_DECIMALS): number {
  const s = units.toString().padStart(decimals + 1, '0')
  const whole = s.slice(0, -decimals)
  const frac  = s.slice(-decimals).replace(/0+$/, '')
  return Number(frac ? `${whole}.${frac}` : whole)
}

// __NEXUM_CCTP_QUOTE_ENGINE__ (part1) do-not-duplicate
// ============================================================
// CCTP V2 QUOTE ENGINE  (Part 1 of the Fast/Standard upgrade)
//
// Everything here is derived from Circle's live docs, verified 2026-08-26:
//   fees:      https://developers.circle.com/cctp/concepts/fees
//   finality:  https://developers.circle.com/cctp/concepts/finality-and-block-confirmations
//   semantics: https://developers.circle.com/cctp/cctp-finality-and-fees
//
// FACTS THAT SHAPE THIS CODE (each one is a bug we are fixing):
//
//   * Standard Transfer is FREE (0 bps) today. The Fast fee (1-14 bps by
//     source chain) is the only protocol fee. The old getBurnFee applied a
//     "2 bps standard fallback" - that fee does not exist. We read the fee
//     from the API and never hardcode it (Circle can flip a per-chain fee
//     switch at any time).
//
//   * The /v2/burn/USDC/fees/{from}/{to} response is an ARRAY. Each entry has
//     { finalityThreshold, minimumFee }. finalityThreshold 1000 = Fast,
//     2000 = Standard. minimumFee is in BASIS POINTS.
//
//   * Circle's own maxFee formula (from their docs), reproduced exactly:
//        protocolFee = amount * round(minimumFee * 100) / 1_000_000
//        maxFee      = protocolFee * 120 / 100        (20% buffer)
//     A maxFee below the required minimum makes the burn REVERT, so the buffer
//     matters. We keep it configurable.
//
//   * The Fast fee is DEDUCTED AT MINT: the recipient receives amount - fee.
//     (Upfront-fee payment via TokenMessengerWithFees is a later phase.)
//
//   * Fast Transfer is only meaningful as a SOURCE where standard attestation
//     is slow. Circle marks fast "N/A" as source for chains whose standard
//     attestation is already fast (Arc, Avalanche, Polygon, Monad here). On
//     those we must fall back to Standard - the toggle is disabled in the UI.
//
// NOTE ON BIGINT: no bigint literals (e.g. 120n) anywhere - this project's
// tsconfig has no explicit ES2020 target, so we build every bigint with
// BigInt(...) exactly as the rest of the file already does.
// ============================================================

export type TransferMode = 'fast' | 'standard'

// ── Fast-Transfer-as-source support, keyed by our chain key ──
//
// TRUE  = Fast gives a real speed win as a source (slow standard finality).
// FALSE = standard attestation is already fast, Circle disables Fast as source.
//
// Verified against the finality table. Anything not listed defaults to FALSE
// (safe: we only offer Fast where we've confirmed it helps).
const FAST_AS_SOURCE: Record<string, boolean> = {
  ethereum: true,
  base:     true,
  arbitrum: true,
  optimism: true,   // "OP Mainnet" in Circle's tables
  unichain: true,
  // Fast NOT available as source (standard is already ~seconds):
  arc:       false,
  avalanche: false,
  polygon:   false, // Polygon PoS standard ~8s
  monad:     false, // ~5s standard
}

export function fastTransferSupported(fromKey: string): boolean {
  return FAST_AS_SOURCE[fromKey] === true
}

// ── Estimated attestation time, seconds (source-chain, per mode) ──
//
// From Circle's finality tables. These are averages for the SOURCE chain's
// attestation; destination mint is near-instant once attested. Testnet timings
// track mainnet closely enough for a UI estimate; we label them "~".
const FAST_ETA_SEC: Record<string, number> = {
  ethereum: 20, base: 8, arbitrum: 8, optimism: 8, unichain: 8,
}
const STD_ETA_SEC: Record<string, number> = {
  ethereum: 1020, base: 1020, arbitrum: 1020, optimism: 1020, unichain: 1020, // ~15-19 min
  arc: 1, avalanche: 8, polygon: 8, monad: 5,
}

export function etaSeconds(fromKey: string, mode: TransferMode): number {
  if (mode === 'fast') return FAST_ETA_SEC[fromKey] ?? 20
  return STD_ETA_SEC[fromKey] ?? 1020
}

// ── Fee table lookup ────────────────────────────────────────
export interface FeeEntry {
  finalityThreshold: number  // 1000 = fast, 2000 = standard
  minimumFeeBps:     number  // basis points
}

/*
  Fetch both fee entries for a route in one call. Returns whatever Circle gives
  us, normalised. If the call fails we return an empty list and the caller
  decides how to degrade (fast unavailable, standard is free anyway).
*/
export async function fetchFeeTable(
  irisBase: string, fromDomain: number, toDomain: number,
): Promise<FeeEntry[]> {
  const url = `${irisBase}/v2/burn/USDC/fees/${fromDomain}/${toDomain}`
  try {
    const res = await fetch(url)
    if (!res.ok) return []
    const data: any = await res.json()
    const rows: any[] = Array.isArray(data) ? data : (data?.data ?? [data])
    return rows
      .map(r => ({
        finalityThreshold: Number(r?.finalityThreshold ?? 0),
        minimumFeeBps:     Number(r?.minimumFee ?? 0),
      }))
      .filter(r => r.finalityThreshold > 0)
  } catch {
    return []
  }
}

function bpsForMode(table: FeeEntry[], mode: TransferMode): number {
  const wantThreshold = mode === 'fast' ? 1000 : 2000
  const exact = table.find(e => e.finalityThreshold === wantThreshold)
  if (exact) return exact.minimumFeeBps
  // Standard is free if the API didn't return a standard row.
  if (mode === 'standard') return 0
  // Fast row missing but caller asked for fast: fall back to the first row.
  return table[0]?.minimumFeeBps ?? 0
}

/*
  Circle's exact maxFee formula (see header). Kept as its own function so both
  the quote and the burn call use identical math - a mismatch here is what
  makes a burn revert.
*/
export function maxFeeFor(
  amountUnits: bigint, minimumFeeBps: number, bufferPct = 20,
): bigint {
  if (minimumFeeBps <= 0) return BigInt(0) // standard/free: maxFee 0 is valid
  // amount * round(bps * 100) / 1_000_000
  const scaled = BigInt(Math.round(minimumFeeBps * 100))
  const million = BigInt(1000000)
  const protocolFee = (amountUnits * scaled) / million
  const buffered = (protocolFee * BigInt(100 + bufferPct)) / BigInt(100)
  // Fast fee must be > 0 to be eligible; floor at 1 unit if math rounds to 0.
  return buffered > BigInt(0) ? buffered : BigInt(1)
}

// ── The quote a caller (hook + UI) consumes ─────────────────
export interface TransferQuote {
  mode:          TransferMode
  feeBps:        number   // protocol fee rate, basis points
  feeUnits:      bigint   // estimated fee actually charged (not the buffer)
  maxFeeUnits:   bigint   // what to pass as maxFee in depositForBurn
  receiveUnits:  bigint   // amount the recipient gets (amount - feeUnits)
  etaSeconds:    number   // estimated time to attestation
  fastSupported: boolean  // is fast available on this source at all
  degraded:      boolean  // caller asked fast but route forces standard
}

/*
  Build a quote for one mode. Never throws - a fee-API outage yields a
  best-effort quote (standard is free; fast floors sensibly) so the UI stays
  usable and the burn still sets a safe maxFee.
*/
export async function getTransferQuote(params: {
  irisBase:    string
  fromKey:     string
  fromDomain:  number
  toDomain:    number
  amountUnits: bigint
  mode:        TransferMode
  bufferPct?:  number
}): Promise<TransferQuote> {
  const { irisBase, fromKey, fromDomain, toDomain, amountUnits, mode } = params

  const fastSupported = fastTransferSupported(fromKey)
  const effectiveMode: TransferMode =
    mode === 'fast' && !fastSupported ? 'standard' : mode
  const degraded = mode === 'fast' && !fastSupported

  const table = await fetchFeeTable(irisBase, fromDomain, toDomain)
  const feeBps = bpsForMode(table, effectiveMode)

  // Estimated fee actually charged = amount * bps / 10_000 (no buffer).
  const feeUnits =
    feeBps > 0 ? (amountUnits * BigInt(feeBps)) / BigInt(10000) : BigInt(0)
  const maxFeeUnits = maxFeeFor(amountUnits, feeBps, params.bufferPct ?? 20)
  const receiveUnits =
    amountUnits > feeUnits ? amountUnits - feeUnits : BigInt(0)

  return {
    mode:          effectiveMode,
    feeBps,
    feeUnits,
    maxFeeUnits,
    receiveUnits,
    etaSeconds:    etaSeconds(fromKey, effectiveMode),
    fastSupported,
    degraded,
  }
}

/*
  Convenience: quote BOTH modes at once for the UI's toggle, sharing a single
  fee-table fetch. Returns fast=null when the source can't do fast.
*/
export async function getBothQuotes(params: {
  irisBase:    string
  fromKey:     string
  fromDomain:  number
  toDomain:    number
  amountUnits: bigint
  bufferPct?:  number
}): Promise<{ fast: TransferQuote | null; standard: TransferQuote }> {
  const { irisBase, fromKey, fromDomain, toDomain, amountUnits } = params
  const table = await fetchFeeTable(irisBase, fromDomain, toDomain)
  const buffer = params.bufferPct ?? 20

  const build = (mode: TransferMode): TransferQuote => {
    const feeBps = bpsForMode(table, mode)
    const feeUnits =
      feeBps > 0 ? (amountUnits * BigInt(feeBps)) / BigInt(10000) : BigInt(0)
    return {
      mode,
      feeBps,
      feeUnits,
      maxFeeUnits:   maxFeeFor(amountUnits, feeBps, buffer),
      receiveUnits:  amountUnits > feeUnits ? amountUnits - feeUnits : BigInt(0),
      etaSeconds:    etaSeconds(fromKey, mode),
      fastSupported: fastTransferSupported(fromKey),
      degraded:      false,
    }
  }

  return {
    fast:     fastTransferSupported(fromKey) ? build('fast') : null,
    standard: build('standard'),
  }
}
