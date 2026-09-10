'use client'
// __NEXUM_USE_DISBURSEMENT_FLOAT__
// Read-only view of the caller's payroll float (the developer-controlled
// disbursement wallet balance, per employer). Payroll pays OUT of this float,
// not the user's own USDC wallet, so this is the balance the payroll UI should
// show. Mirrors the fetch DisbursementFloatCard already does, exposed as a hook
// so the batch summary and the card read one source.
import { useQuery } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface DisbursementFloat {
  configured: boolean
  balance:    number | null
}

export function useDisbursementFloat() {
  const { address } = useAccount()
  return useQuery<DisbursementFloat>({
    queryKey: ['disbursement-float', address],
    enabled:  Boolean(address),
    queryFn:  async () => {
      const res  = await fetch(`${API}/payroll/disbursement/status?wallet=${address}`)
      const data = await res.json().catch(() => ({}))
      return {
        configured: Boolean(data.configured),
        balance:    typeof data.balance === 'number' ? data.balance : null,
      }
    },
    staleTime:       30_000,
    refetchInterval: 30_000,
  })
}
