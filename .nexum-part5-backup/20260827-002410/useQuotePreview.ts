// __NEXUM_QUOTE_PREVIEW__ (part3) live Fast/Standard quote for the bridge UI
'use client'
import { useEffect, useRef, useState } from 'react'
import { chainByKey, irisBase } from '@/lib/cctp-chains'
import {
  getBothQuotes, toUnits, fromUnits,
  type TransferQuote,
} from '@/lib/cctp-client'

/*
  Live quote preview for the bridge card.

  The bridge hook only resolves a quote once a transfer is actually running.
  For the pre-submit UI we need both Fast and Standard quotes as the user types,
  so they can see the fee, the amount that lands, and the ETA BEFORE signing.

  This hook:
    * debounces on amount so we don't hammer Circle's fee API per keystroke
    * fetches both modes in one call (getBothQuotes shares one fee-table fetch)
    * returns fast=null when the source chain can't do Fast, so the UI can
      disable the Fast option and explain why
    * never throws - a fee-API hiccup just yields loading=false with whatever
      it could resolve (Standard is free, so it always has a sane answer)
*/
export interface QuotePreview {
  loading:  boolean
  fast:     TransferQuote | null
  standard: TransferQuote | null
  /** true when the source chain supports Fast as a source at all */
  fastAvailable: boolean
}

const EMPTY: QuotePreview = {
  loading: false, fast: null, standard: null, fastAvailable: false,
}

export function useQuotePreview(
  fromKey: string, toKey: string, amount: string,
): QuotePreview {
  const [preview, setPreview] = useState<QuotePreview>(EMPTY)
  // Guards against a slow earlier request overwriting a newer one.
  const reqId = useRef(0)

  useEffect(() => {
    const amt = Number(amount)
    const from = chainByKey(fromKey)
    const to   = chainByKey(toKey)

    // Nothing to quote yet: clear without a network call.
    if (!from || !to || fromKey === toKey || !(amt > 0)) {
      setPreview(EMPTY)
      return
    }

    const id = ++reqId.current
    setPreview(p => ({ ...p, loading: true }))

    const t = setTimeout(async () => {
      try {
        const amountUnits = toUnits(amt)
        const { fast, standard } = await getBothQuotes({
          irisBase:   irisBase(),
          fromKey:    from.key,
          fromDomain: from.domain,
          toDomain:   to.domain,
          amountUnits,
        })
        if (id !== reqId.current) return // a newer request superseded this one
        setPreview({
          loading: false,
          fast,
          standard,
          fastAvailable: fast !== null,
        })
      } catch {
        if (id !== reqId.current) return
        setPreview({ ...EMPTY, loading: false })
      }
    }, 350)

    return () => clearTimeout(t)
  }, [fromKey, toKey, amount])

  return preview
}

/* Format a USDC unit amount (bigint) for display, trimming to `dp` decimals. */
export function formatUnits(units: bigint, dp = 4): string {
  const n = fromUnits(units)
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 0, maximumFractionDigits: dp,
  })
}

/* Human ETA from seconds: "~8s", "~2 min", "~15-19 min" style. */
export function formatEta(seconds: number): string {
  if (seconds <= 0) return 'instant'
  if (seconds < 60) return `~${seconds}s`
  const mins = Math.round(seconds / 60)
  return `~${mins} min`
}
