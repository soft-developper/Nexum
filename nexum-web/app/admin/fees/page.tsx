'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Loader2, RefreshCw, AlertCircle, X, Coins, ShieldAlert } from 'lucide-react'

type FeeAmount = { base: string; usdc: number }
type ProtocolFees = {
  key:       string
  label:     string
  accrued:   FeeAmount
  withdrawn: FeeAmount
  available: FeeAmount
}
type FeesResponse = {
  decimals:       number
  protocols:      ProtocolFees[]
  totalAvailable: FeeAmount
}

function usdc(n: number) {
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 6 })
}

export default function AdminFees() {
  const { admin, loading: authLoading } = useAdminAuth()
  const [data,    setData]    = useState<FeesResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error,   setError]   = useState<string | null>(null)

  // withdraw modal state
  const [wOpen,   setWOpen]   = useState(false)
  const [wProto,  setWProto]  = useState<ProtocolFees | null>(null)
  const [wTo,     setWTo]     = useState('')
  const [wAmount, setWAmount] = useState('')
  const [wBusy,   setWBusy]   = useState(false)
  const [wErr,    setWErr]    = useState<string | null>(null)
  const [notice,  setNotice]  = useState<string | null>(null)

  const isSuper = admin?.role === 'super_admin'

  async function load() {
    setLoading(true)
    setError(null)
    try {
      const res = await adminFetch('/admin/manage/fees')
      if (res.status === 403) { setError('Fee treasury is restricted to the main admin.'); setData(null); return }
      if (!res.ok) { setError((await res.json()).error ?? 'Failed to load fees'); return }
      setData(await res.json())
    } catch (e: any) {
      setError(e.message ?? 'Failed to load fees')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { if (!authLoading && isSuper) load() }, [authLoading, isSuper])

  function openWithdraw(p: ProtocolFees) {
    setWProto(p)
    setWTo('')
    setWAmount('')
    setWErr(null)
    setWOpen(true)
  }

  function fillMax() {
    if (wProto) setWAmount(String(wProto.available.usdc))
  }

  async function submitWithdraw() {
    if (!wProto) return
    const amt = Number(wAmount)
    if (!wTo.trim())                          { setWErr('Enter a recipient address'); return }
    if (!Number.isFinite(amt) || amt <= 0)    { setWErr('Enter a valid amount');       return }
    if (amt > wProto.available.usdc)          { setWErr('Amount exceeds available fees'); return }

    setWBusy(true)
    setWErr(null)
    try {
      const res = await adminFetch('/admin/manage/fees/withdraw', {
        method: 'POST',
        body: JSON.stringify({ protocol: wProto.key, to: wTo.trim(), amount: amt }),
      })
      const body = await res.json()
      if (!res.ok) { setWErr(body.error ?? 'Withdrawal failed'); return }
      setWOpen(false)
      setNotice(`Withdrew ${usdc(amt)} USDC of ${wProto.label} fees. Tx ${String(body.txHash).slice(0, 14)}...`)
      await load()
    } catch (e: any) {
      setWErr(e.message ?? 'Withdrawal failed')
    } finally {
      setWBusy(false)
    }
  }

  // Non-super admins never see fee data (server also enforces this).
  if (!authLoading && !isSuper) {
    return (
      <AdminShell>
        <div className="mx-auto mt-16 max-w-md rounded-xl border border-app-border bg-app-surface p-8 text-center">
          <ShieldAlert className="mx-auto mb-3 h-8 w-8 text-app-muted" />
          <h1 className="text-lg font-semibold text-app-text">Restricted</h1>
          <p className="mt-1.5 text-sm text-app-muted">
            The fee treasury is available to the main admin only.
          </p>
        </div>
      </AdminShell>
    )
  }

  return (
    <AdminShell>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Platform fees</h1>
          <p className="mt-0.5 text-xs text-app-muted">Collected on-chain, withdrawable by the main admin.</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {notice && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-app-bg px-3 py-2.5 text-xs text-app-text">
          <span className="flex items-start gap-2">
            <Coins className="mt-0.5 h-3.5 w-3.5 shrink-0 text-app-accent-text" />{notice}
          </span>
          <button onClick={() => setNotice(null)} className="shrink-0 text-app-muted hover:text-app-text">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {error && (
        <div className="mb-4 flex items-start justify-between gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
          <span className="flex items-start gap-2">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </span>
          <button onClick={() => setError(null)} className="shrink-0 hover:text-red-300">
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {loading ? (
        <div className="flex h-40 items-center justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
        </div>
      ) : data ? (
        <>
          {/* Total available */}
          <div className="mb-5 rounded-xl border border-app-border bg-app-surface p-5">
            <p className="text-xs text-app-muted">Total available to withdraw</p>
            <p className="mt-1 text-3xl font-semibold tracking-tight text-app-text">
              {usdc(data.totalAvailable.usdc)}
              <span className="ml-1.5 text-base font-normal text-app-muted">USDC</span>
            </p>
          </div>

          {/* Per-protocol */}
          <div className="grid gap-3 sm:grid-cols-2">
            {data.protocols.map(p => (
              <div key={p.key} className="rounded-xl border border-app-border bg-app-surface p-4">
                <div className="flex items-start justify-between">
                  <div>
                    <p className="text-sm font-medium text-app-text">{p.label}</p>
                    <p className="mt-2 text-2xl font-semibold text-app-text">
                      {usdc(p.available.usdc)}
                      <span className="ml-1 text-sm font-normal text-app-muted">USDC</span>
                    </p>
                    <p className="mt-0.5 text-[11px] text-app-muted">available now</p>
                  </div>
                  <Button size="sm" variant="default"
                    disabled={p.available.usdc <= 0}
                    onClick={() => openWithdraw(p)}>
                    Withdraw
                  </Button>
                </div>
                <div className="mt-4 flex gap-6 border-t border-app-border pt-3 text-[11px] text-app-muted">
                  <span>Collected: <span className="text-app-text">{usdc(p.accrued.usdc)}</span></span>
                  <span>Withdrawn: <span className="text-app-text">{usdc(p.withdrawn.usdc)}</span></span>
                </div>
              </div>
            ))}
          </div>
        </>
      ) : null}

      {/* Withdraw modal */}
      {wOpen && wProto && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
          onClick={() => !wBusy && setWOpen(false)}>
          <div className="w-full max-w-sm rounded-xl border border-app-border bg-app-surface p-5"
            onClick={e => e.stopPropagation()}>
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-sm font-semibold text-app-text">Withdraw {wProto.label} fees</h2>
              <button onClick={() => !wBusy && setWOpen(false)} className="text-app-muted hover:text-app-text">
                <X className="h-4 w-4" />
              </button>
            </div>

            <label className="mb-1 block text-xs text-app-muted">Recipient address</label>
            <input value={wTo} onChange={e => setWTo(e.target.value)} placeholder="0x..."
              className="mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none focus:border-app-accent" />

            <div className="mb-1 flex items-center justify-between">
              <label className="text-xs text-app-muted">Amount (USDC)</label>
              <button onClick={fillMax} className="text-[11px] text-app-accent-text hover:underline">
                Max {usdc(wProto.available.usdc)}
              </button>
            </div>
            <input value={wAmount} onChange={e => setWAmount(e.target.value)} inputMode="decimal" placeholder="0.00"
              className="w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none focus:border-app-accent" />

            {wErr && (
              <p className="mt-3 flex items-start gap-1.5 text-xs text-red-400">
                <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{wErr}
              </p>
            )}

            <div className="mt-5 flex justify-end gap-2">
              <Button size="sm" variant="outline" onClick={() => setWOpen(false)} disabled={wBusy}>Cancel</Button>
              <Button size="sm" variant="default" onClick={submitWithdraw} disabled={wBusy}>
                {wBusy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Withdraw'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </AdminShell>
  )
}
