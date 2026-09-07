import { Router } from 'express'
import { db }     from '../db/client'
import { sql }    from 'drizzle-orm'
import { pruneSend } from '../services/retention'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Whether the transactions table has the from_chain column. Detected once and
// cached. This makes the insert resilient: if the 0022/0023 migration hasn't
// landed on this database yet, we simply omit the column instead of throwing
// (which would drop the whole send record). Re-checked lazily until found.
let _fromChainCol: boolean | null = null
async function hasFromChainColumn(): Promise<boolean> {
  if (_fromChainCol === true) return true
  try {
    const info = await db.run(sql`PRAGMA table_info(transactions)`)
    const cols = parseRows(info).map((c: any) => c.name)
    _fromChainCol = cols.includes('from_chain')
  } catch {
    _fromChainCol = false
  }
  return _fromChainCol === true
}

// GET /transactions?wallet=0x
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM transactions
          WHERE LOWER(wallet_address) = ${wallet}
          ORDER BY created_at DESC`
    )
    res.json(parseRows(rows))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /transactions create
router.post('/', async (req, res) => {
  const {
    walletAddress, fromCurrency, toCurrency,
    fromAmount, toAmount, spreadFee, networkFee,
    arcTxHash, memoId, reference, corridorId, corridorStep,
    fromChain,
  } = req.body

  const now = Math.floor(Date.now() / 1000)
  const id  = arcTxHash ?? `tx-${now}-${Math.random().toString(36).slice(2,8)}`

  try {
    // Include from_chain only if the column exists on this DB (see 0023). This
    // keeps sends recording even if the column migration hasn't landed yet.
    if (await hasFromChainColumn()) {
      await db.run(
        sql`INSERT OR IGNORE INTO transactions
            (id, wallet_address, from_currency, to_currency,
             from_amount, to_amount, spread_fee, network_fee,
             arc_tx_hash, memo_id, reference,
             corridor_id, corridor_step, from_chain, status, created_at)
            VALUES
            (${id}, ${walletAddress.toLowerCase()}, ${fromCurrency}, ${toCurrency},
             ${fromAmount}, ${toAmount}, ${spreadFee ?? 0}, ${networkFee ?? 0.001},
             ${arcTxHash ?? null}, ${memoId ?? null}, ${reference ?? null},
             ${corridorId ?? null}, ${corridorStep ?? null}, ${fromChain ?? null}, 'pending', ${now})`
      )
    } else {
      await db.run(
        sql`INSERT OR IGNORE INTO transactions
            (id, wallet_address, from_currency, to_currency,
             from_amount, to_amount, spread_fee, network_fee,
             arc_tx_hash, memo_id, reference,
             corridor_id, corridor_step, status, created_at)
            VALUES
            (${id}, ${walletAddress.toLowerCase()}, ${fromCurrency}, ${toCurrency},
             ${fromAmount}, ${toAmount}, ${spreadFee ?? 0}, ${networkFee ?? 0.001},
             ${arcTxHash ?? null}, ${memoId ?? null}, ${reference ?? null},
             ${corridorId ?? null}, ${corridorStep ?? null}, 'pending', ${now})`
      )
    }
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

/*
  PATCH /transactions/:hash, update status after on-chain confirmation.

  IMPORTANT DISTINCTION. A confirmed on-chain transfer means the USDC left the
  user's wallet. For a USDC to fiat conversion that is NOT the same as the
  conversion being SETTLED: settled should mean the recipient actually received
  their money, which happens later, via a payout provider.

  Calling that 'settled' told users their money had arrived when it had not.
  So an on-chain confirmation now records 'funded' for fiat-bound conversions,
  and only the payout completing marks them 'settled'. Callers can still pass an
  explicit status for other cases.
*/
router.patch('/:hash', async (req, res) => {
  const { status } = req.body
  const now        = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE transactions
          SET status     = ${status ?? 'funded'},
              settled_at = ${status === 'settled' ? now : null}
          WHERE arc_tx_hash = ${req.params.hash}
             OR id          = ${req.params.hash}`
    )
    // Cap history when a send reaches a terminal state (per-user, terminal-only).
    if (status === 'settled' || status === 'failed') {
      try {
        const owner = parseRows(await db.run(sql`
          SELECT wallet_address FROM transactions
          WHERE arc_tx_hash = ${req.params.hash} OR id = ${req.params.hash} LIMIT 1`))[0]
        if (owner?.wallet_address) { void pruneSend(owner.wallet_address) }
      } catch {}
    }
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /transactions/ref/:ref
router.get('/ref/:ref', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM transactions WHERE reference = ${req.params.ref} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Not found' })
    res.json(r[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
