'use client'
import { useState, useEffect } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { useAccount, useWriteContract, usePublicClient, useConfig, useChainId, useDisconnect } from 'wagmi'
import { parseUnits } from 'viem'
import { useInvoiceByRef } from '@/hooks/useInvoices'
import { useCreatePayment } from '@/hooks/usePayments'
import { useFXRates } from '@/hooks/useFXRate'
import { ClientOnly } from '@/components/ui/client-only'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ConnectButton } from '@/components/wallet/ConnectButton'
import { formatAmount } from '@/lib/utils'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { arcTestnet } from '@/lib/arc-chain'
import { ensureArcChain } from '@/lib/ensure-arc-chain'
import { useInvoiceCirclePay, hasCircleSession } from '@/hooks/useInvoiceCirclePay'
import { useAuth } from '@/hooks/useAuth'
import { clearSigningSession } from '@/hooks/useCircleTx'
import { clearSession } from '@/hooks/useAuth'
import {
  FileText, CheckCircle, AlertCircle,
  Loader2, ExternalLink, Wallet, XCircle,
  ArrowRight,
} from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

type PayStatus =
  | 'idle'
  | 'submitting'
  | 'confirming'
  | 'success'
  | 'failed'
  | 'error'

export function InvoicePayInner() {
  return <ClientOnly><PayContent /></ClientOnly>
}

function PayContent() {
  const { ref }                          = useParams()
  const router                          = useRouter()
  const { payWithCircle, step: circleStep } = useInvoiceCirclePay()
  const { address, isConnected }         = useAccount()
  const { account }                       = useAuth()
  const circleAddress                     = account?.walletAddress ?? null
  const { disconnect }                    = useDisconnect()

  // Fully sign out of the Nexum (Circle) session on the pay page, so a creator
  // who opened their own invoice can switch to a different account to pay.
  // Mirrors AccountMenu's sign-out, then reloads the pay page fresh.
  function signOutHere() {
    try { clearSigningSession() } catch {}
    try { clearSession() } catch {}
    try { disconnect() } catch {}
    window.location.reload()
  }
  const publicClient                     = usePublicClient({ chainId: arcTestnet.id })
  const { data: invoice, isLoading }     = useInvoiceByRef(ref as string)
  const { data: rates = [] }             = useFXRates()
  const createPayment                    = useCreatePayment()
  const { writeContractAsync }           = useWriteContract()
  const wagmiConfig                      = useConfig()
  const currentChainId                   = useChainId()

  const [status, setStatus] = useState<PayStatus>('idle')
  const [txHash, setTxHash] = useState<string | null>(null)
  const [errMsg, setErrMsg] = useState<string | null>(null)

  // Reactive Circle-session state. hasCircleSession() is a one-shot read; on the
  // public pay page the session can appear AFTER mount (the payer returns from
  // /signin), so we track it in state and re-check on mount and on window focus.
  // Without this the CTA stayed on "Sign in to pay" until a manual reload.
  const [circleReady, setCircleReady] = useState(false)
  const busyPaying = (status as PayStatus) === 'submitting' || (status as PayStatus) === 'confirming'
  // True when the payer just came back from signing in specifically to pay this
  // invoice - we then show a "Ready to pay - Confirm" state instead of a silent
  // page, and never auto-charge.
  const [resumePay, setResumePay] = useState(false)

  useEffect(() => {
    const refStr = String(ref ?? '')
    function recheck() {
      const live = hasCircleSession()
      setCircleReady(live)
      // If we stashed "resume this invoice" before redirecting to signin and we
      // now have a live session for the same invoice, surface the confirm state.
      try {
        const pending = sessionStorage.getItem('nexum_invoice_resume')
        if (live && pending && pending === refStr) {
          setResumePay(true)
          sessionStorage.removeItem('nexum_invoice_resume')
        }
      } catch { /* sessionStorage unavailable - ignore */ }
    }
    recheck()
    window.addEventListener('focus', recheck)
    return () => window.removeEventListener('focus', recheck)
  }, [ref])

  // ── Convert invoice amount to USDC ──────────────────────────
  // Invoice can be in any currency (NGN, GHS, KES, ZAR, EGP, EURC, USDC)
  // Transfer always happens in USDC on-chain
  function getUSDCAmount(amount: number, currency: string): number {
    if (currency === 'USDC') return amount

    if (currency === 'EURC') {
      // EURC/USDC rate = local units per USDC (inverted for EUR)
      const r = rates.find(r => r.pair === 'EURC/USDC')?.rate
      return r ? amount / r : amount * 1.09
    }

    // Local currency: rate = local units per 1 USDC
    // So usdcAmount = localAmount / rate
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate || rate <= 0) return 0
    return amount / rate
  }

  if (isLoading) return (
    <div className="flex h-64 items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-app-accent-text" />
    </div>
  )

  if (!invoice) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <AlertCircle className="h-8 w-8 text-red-400" />
      <p className="text-sm text-app-muted">Invoice not found</p>
    </div>
  )

  // USDC amount the payer will actually send on-chain
  const usdcAmount     = getUSDCAmount(invoice.amount, invoice.currency)
  const isLocalCcy     = invoice.currency !== 'USDC' && invoice.currency !== 'EURC'
  const ratesLoaded    = rates.length > 0
  const rateAvailable  = !isLocalCcy || usdcAmount > 0

  const alreadyPaid  = invoice.status === 'paid'
  const isCancelled  = invoice.status === 'cancelled'
  // A creator can pay with an external wallet OR their signed-in Nexum (Circle)
  // wallet, so "is this the creator?" must check BOTH addresses. Previously it
  // only checked the external wagmi address, so a creator signed into Nexum
  // (whose external address is empty) slipped through and could pay their own
  // invoice from the same account.
  const creatorLc    = invoice.creator_address.toLowerCase()
  const isCreator    = address?.toLowerCase() === creatorLc
                       || circleAddress?.toLowerCase() === creatorLc
  const wrongPayer   = invoice.payer_address &&
    address?.toLowerCase() !== invoice.payer_address.toLowerCase()

  async function handlePay() {
    if (!address || !isConnected || !invoice || usdcAmount <= 0) return
    if (isCreator) { setStatus('error'); setErrMsg('You created this invoice - you cannot pay it from the same account.'); return }
    setStatus('submitting')
    setErrMsg(null)
    setTxHash(null)

    let hash: `0x${string}` | null = null

    try {
      // Make sure the external wallet is on Arc (adds the chain if missing).
      await ensureArcChain(wagmiConfig, currentChainId)

      // Plain USDC transfer for both EOA and Circle payers. The invoice is
      // reconciled by its DB memo_ref (matched server-side), so no on-chain
      // memo is needed here - dropping it removes the Arc memo precompile as a
      // failure source and keeps the pay path simple and robust.
      const usdcRaw = parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)
      const target  = invoice.creator_address as `0x${string}`

      hash = await writeContractAsync({
        address:      CONTRACTS.USDC,
        abi:          USDC_ABI,
        functionName: 'transfer',
        args:         [target, usdcRaw],
      })

      setTxHash(hash)
      setStatus('confirming')

      // On-chain receipt is the SOLE source of truth for success/failure.
      let receiptStatus: 'success' | 'reverted' = 'success'
      if (publicClient) {
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        receiptStatus = receipt.status
      }

      if (receiptStatus === 'reverted') {
        // Genuine on-chain failure: no funds moved.
        setStatus('failed')
        await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
          method:  'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({ txHash: hash, status: 'failed' }),
        }).catch(() => {})
        await createPayment.mutateAsync({
          recipientAddress: invoice.creator_address,
          amount:           usdcAmount,
          currency:         'USDC',
          description:      `FAILED: ${invoice.description ?? invoice.memo_ref}`,
          invoiceRef:       invoice.memo_ref,
          arcTxHash:        hash,
          status:           'failed',
        } as any).catch(() => {})
        return
      }

      // ── SUCCESS ────────────────────────────────────────────
      // Funds have moved. Mark the invoice paid FIRST (authoritative);
      // everything after is best-effort bookkeeping.
      await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ txHash: hash, payerAddress: address, usdcAmount }),
      }).catch(() => {})

      // Record the payment row - NON-FATAL. A failure here must never flip the
      // UI to "failed" or reverse the paid invoice; money already moved and the
      // invoice is already marked paid above.
      try {
        await createPayment.mutateAsync({
          recipientAddress: invoice.creator_address,
          amount:           usdcAmount,
          currency:         'USDC',
          description:      invoice.description ?? invoice.memo_ref,
          invoiceRef:       invoice.memo_ref,
          arcTxHash:        hash,
        })
      } catch (bookErr) {
        console.error('[invoice] payment record failed (non-fatal):', bookErr)
      }

      setStatus('success')

    } catch (err: any) {
      // Reached only if the tx never confirmed. A confirmed success already
      // returned above, so we do NOT send a 'failed' PATCH here - that stray
      // PATCH was what reverted genuinely-paid invoices back to 'sent'.
      const msg = err?.shortMessage ?? err?.message ?? 'Transaction failed'
      setStatus('error')
      setErrMsg(msg)
    }
  }

  async function handlePayWithCircle() {
    if (!invoice || usdcAmount <= 0) return
    if (isCreator) { setStatus('error'); setErrMsg('You created this invoice - you cannot pay it from the same account.'); return }
    setStatus('submitting'); setErrMsg(null); setTxHash(null)
    try {
      const target = invoice.creator_address as string
      const outcome = await payWithCircle(target, usdcAmount)
      if (outcome.needsSignin) {
        // No live Circle session. Do NOT try to run Circle login on this public
        // page (the SDK login callback lives on /signin - attempting it here is
        // what made the popup flicker open/closed). Stash a resume marker so the
        // return lands on the "Ready to pay" confirm state, then hand off to the
        // signin page which owns the full, working auth flow.
        try { sessionStorage.setItem('nexum_invoice_resume', String(invoice.memo_ref)) } catch {}
        setStatus('idle')
        router.push('/signin?returnTo=' + encodeURIComponent('/pay/' + invoice.memo_ref))
        return
      }
      const hash = outcome.result.txHash as `0x${string}` | undefined
      if (hash) setTxHash(hash)
      // Persist invoice-paid + payment record (same as the external path).
      await fetch(`${API}/invoices/ref/${invoice.memo_ref}/pay`, {
        method: 'PATCH', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ txHash: hash ?? null, payerAddress: null, usdcAmount }),
      }).catch(() => {})
      await createPayment.mutateAsync({
        recipientAddress: invoice.creator_address,
        amount: usdcAmount, currency: 'USDC',
        description: invoice.description ?? invoice.memo_ref,
        invoiceRef: invoice.memo_ref, arcTxHash: hash,
      } as any).catch(() => {})
      setStatus('success')
    } catch (err: any) {
      setStatus('error'); setErrMsg(err?.shortMessage ?? err?.message ?? 'Circle payment failed')
    }
  }

  return (
    <div className="mx-auto max-w-lg">
      <div className="rounded-2xl border border-app-border bg-app-surface p-6">

        {/* Header */}
        <div className="mb-5 flex items-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-app-bg">
            <FileText className="h-6 w-6 text-app-accent-text" />
          </div>
          <div>
            <p className="text-sm font-medium text-app-text">Payment request</p>
            <p className="font-mono text-xs text-app-accent-text">{invoice.memo_ref}</p>
          </div>
          <Badge className="ml-auto" variant={
            alreadyPaid ? 'success' : isCancelled ? 'danger' : 'arc'
          }>
            {invoice.status}
          </Badge>
        </div>

        {/* Amount show original + USDC equivalent */}
        <div className="mb-5 rounded-xl bg-app-bg p-5 text-center">
          <p className="text-xs text-app-muted">Amount due</p>
          <p className="mt-1 font-mono text-4xl font-bold text-app-text">
            {formatAmount(invoice.amount)}
          </p>
          <p className="text-sm text-app-accent-text">{invoice.currency}</p>

          {/* USDC conversion shown when invoice is in local currency */}
          {isLocalCcy && (
            <div className="mt-3 flex items-center justify-center gap-2">
              <span className="text-xs text-app-muted">You will pay</span>
              <div className="flex items-center gap-1.5 rounded-full border border-app-accent/30 bg-app-accent/10 px-3 py-1">
                <ArrowRight className="h-3 w-3 text-app-accent-text" />
                {!ratesLoaded ? (
                  <span className="text-xs text-app-muted animate-pulse">Loading rate…</span>
                ) : usdcAmount > 0 ? (
                  <span className="font-mono text-sm font-semibold text-app-accent-text">
                    {formatAmount(usdcAmount, 6)} USDC
                  </span>
                ) : (
                  <span className="text-xs text-red-400">Rate unavailable</span>
                )}
              </div>
            </div>
          )}

          {/* Rate used */}
          {isLocalCcy && usdcAmount > 0 && (
            <p className="mt-1.5 text-[10px] text-app-muted">
              Rate: 1 USDC = {rates.find(r => r.pair === `${invoice.currency}/USDC`)?.rate.toLocaleString()} {invoice.currency}
            </p>
          )}
        </div>

        {/* Invoice details */}
        <div className="mb-5 space-y-2 text-xs">
          {[
            ['From',        (invoice as any).creator_username
                              ? '@' + (invoice as any).creator_username
                              : ((invoice as any).creator_display_name
                                  ?? (invoice.creator_address.slice(0,6) + '…' + invoice.creator_address.slice(-4)))],
            ['Description', invoice.description ?? '-'],
            ['Due',         invoice.due_date
              ? new Date(invoice.due_date * 1000).toLocaleDateString()
              : 'No deadline'],
          ].map(([l, v]) => (
            <div key={l} className="flex justify-between">
              <span className="text-app-muted">{l}</span>
              <span className="text-app-text">{v}</span>
            </div>
          ))}
          {invoice.notes && (
            <div className="rounded-lg bg-app-bg p-2.5 text-app-muted">{invoice.notes}</div>
          )}
        </div>

        {/* Payment status UI */}
        {status === 'success' ? (
          <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
            <CheckCircle className="mx-auto mb-2 h-8 w-8 text-emerald-400" />
            <p className="font-medium text-emerald-400">Payment confirmed on-chain!</p>
            <p className="mt-1 text-xs text-emerald-700 dark:text-emerald-600">
              {formatAmount(usdcAmount, 6)} USDC sent · Invoice marked as paid
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-app-accent-text hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View on ArcScan
              </a>
            )}
          </div>

        ) : status === 'failed' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4 text-center">
            <XCircle className="mx-auto mb-2 h-8 w-8 text-red-400" />
            <p className="font-medium text-red-400">Transaction reverted on-chain</p>
            <p className="mt-1 text-xs text-red-600">
              The transaction failed on Arc. Your USDC was not deducted.
            </p>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 inline-flex items-center gap-1 text-xs text-red-400 hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> View failed tx
              </a>
            )}
            <Button className="mt-3 w-full" onClick={() => {
              setStatus('idle'); setTxHash(null); setErrMsg(null)
            }}>
              Try again
            </Button>
          </div>

        ) : status === 'error' ? (
          <div className="rounded-xl border border-red-900/50 bg-red-900/20 p-4">
            <div className="flex items-start gap-2">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-400" />
              <div>
                <p className="text-sm font-medium text-red-400">Payment failed</p>
                <p className="mt-0.5 text-xs text-red-600">{errMsg}</p>
              </div>
            </div>
            <Button className="mt-3 w-full" onClick={() => {
              setStatus('idle'); setErrMsg(null)
            }}>
              Try again
            </Button>
          </div>

        ) : status === 'submitting' ? (
          <div className="rounded-xl bg-app-bg p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-app-accent-text" />
              <div>
                <p className="text-sm font-medium text-app-text">Waiting for signature…</p>
                <p className="text-xs text-app-muted">Approve in your wallet</p>
              </div>
            </div>
          </div>

        ) : status === 'confirming' ? (
          <div className="rounded-xl bg-app-bg p-4">
            <div className="flex items-center gap-3">
              <Loader2 className="h-5 w-5 animate-spin shrink-0 text-app-accent-text" />
              <div className="flex-1">
                <p className="text-sm font-medium text-app-text">Confirming on Arc…</p>
                <p className="text-xs text-app-muted">Waiting for on-chain confirmation</p>
              </div>
            </div>
            {txHash && (
              <a href={`https://testnet.arcscan.app/tx/${txHash}`}
                target="_blank" rel="noopener noreferrer"
                className="mt-2 flex items-center gap-1 text-xs text-app-accent-text hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> Track on ArcScan
              </a>
            )}
          </div>

        ) : alreadyPaid ? (
          <div className="rounded-xl bg-emerald-900/20 p-4 text-center text-sm text-emerald-400">
            ✓ This invoice has already been paid
          </div>

        ) : isCancelled ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-sm text-red-400">
            This invoice has been cancelled
          </div>

        ) : isCreator ? (
          <div className="rounded-xl bg-amber-900/20 p-4 text-center">
            <p className="mb-3 text-xs text-amber-400">
              You are the owner of this invoice - you can't pay it from the same account. Share this link with your payer.
            </p>
            <p className="mb-2 text-[11px] text-app-muted">
              Paying on someone else's behalf? Switch to a different account or wallet:
            </p>
            {isConnected && (
              <Button variant="outline" size="sm" className="mb-2 w-full" onClick={() => disconnect()}>
                Disconnect wallet
              </Button>
            )}
            {circleAddress && (
              <Button variant="outline" size="sm" className="w-full" onClick={signOutHere}>
                Sign out of {account?.username ? '@' + account.username : 'this account'}
              </Button>
            )}
          </div>

        ) : wrongPayer ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            This invoice is addressed to a specific wallet, connected wallet doesn't match
          </div>

        ) : !isConnected ? (
          <div className="rounded-xl bg-app-bg p-4 text-center">
            {resumePay && circleReady && (
              <div className="mb-4 rounded-xl border border-app-accent/30 bg-app-accent/10 p-4">
                <CheckCircle className="mx-auto mb-2 h-6 w-6 text-app-accent-text" />
                <p className="mb-1 text-sm font-medium text-app-text">You're signed in - ready to pay</p>
                <p className="mb-3 text-xs text-app-muted">
                  Paying {formatAmount(usdcAmount)} USDC from your Nexum wallet.
                </p>
                <Button className="w-full" onClick={handlePayWithCircle}
                  disabled={busyPaying}>
                  {busyPaying
                    ? <><Loader2 className="h-4 w-4 animate-spin" /> {circleStep ?? 'Processing'}…</>
                    : 'Confirm payment'}
                </Button>
              </div>
            )}
            <Wallet className="mx-auto mb-2 h-6 w-6 text-app-muted" />
            <p className="mb-3 text-sm text-app-muted">
              Connect your wallet to pay this invoice
            </p>
            <div className="flex justify-center">
              <ConnectButton label="Connect wallet to pay" />
            </div>
            <p className="mt-2 text-[10px] text-app-muted">
              MetaMask, WalletConnect or any injected wallet holding USDC on Arc. No account needed.
            </p>
            <div className="my-3 flex items-center gap-2">
              <div className="h-px flex-1 bg-app-border" />
              <span className="text-[10px] text-app-muted">or</span>
              <div className="h-px flex-1 bg-app-border" />
            </div>
            <Button variant="outline" className="w-full" onClick={handlePayWithCircle}
              disabled={busyPaying}>
              {circleReady ? 'Pay with your Nexum wallet' : 'Sign in to pay with Nexum wallet'}
            </Button>
            <p className="mt-2 text-[10px] text-app-muted">
              Use your Circle-powered Nexum wallet. New here? Signing in creates one for you.
            </p>
          </div>

        ) : !ratesLoaded && isLocalCcy ? (
          <div className="rounded-xl bg-app-bg p-4 text-center text-xs text-app-muted">
            <Loader2 className="mx-auto mb-2 h-5 w-5 animate-spin" />
            Loading exchange rates…
          </div>

        ) : !rateAvailable ? (
          <div className="rounded-xl bg-red-900/20 p-4 text-center text-xs text-red-400">
            Exchange rate for {invoice.currency} is currently unavailable.
            Please try again in a moment.
          </div>

        ) : (
          <>
            <Button className="w-full" size="lg" onClick={handlePay}>
              Pay {isLocalCcy
                ? `${formatAmount(usdcAmount, 4)} USDC (≈ ${formatAmount(invoice.amount)} ${invoice.currency})`
                : `${formatAmount(invoice.amount)} USDC`
              }
            </Button>
            <p className="mt-2 text-center text-[10px] text-app-muted">
              {isLocalCcy
                ? `${invoice.currency} converted to USDC at live rate · `
                : ''}
              Memo ref: {invoice.memo_ref}
            </p>
            {/* Let a connected external wallet switch to the Nexum-wallet option.
                Without this a hard-connected wallet had no way back to the choice
                screen. Disconnecting returns to the connect/sign-in options. */}
            <button
              onClick={() => disconnect()}
              disabled={busyPaying}
              className="mt-3 flex w-full items-center justify-center gap-1 text-xs text-app-muted transition-colors hover:text-app-text disabled:opacity-50"
            >
              Disconnect / use a different method
            </button>
          </>
        )}
      </div>
    </div>
  )
}
