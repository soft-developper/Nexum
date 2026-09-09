'use client'
// Pay an invoice from the user's CIRCLE (user-controlled) wallet.
// v2: routes payment THROUGH the vault so the 0.1% platform fee is split
// on-chain (the vault keeps the fee and forwards the net to the creator).
// Two device-signed steps, same primitive the bridge uses (executeContractCall):
//   1. approve(vault, amount) on USDC
//   2. payInvoice(invoiceId, creator, amount) on the vault
// No memo (Circle SCA can't use Arc's Memo precompile); the invoice is keyed
// on-chain by keccak256(memo_ref) and reconciled by memo_ref server-side.
import { useState } from 'react'
import { keccak256, toHex } from 'viem'
import {
  getSigningSession, executeContractCall, NeedsReauthError,
} from '@/hooks/useCircleTx'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

const ARC_CHAIN_KEY = 'arc'

export interface CirclePayResult { txHash?: string; state: string }

export function hasCircleSession(): boolean {
  return !!getSigningSession()
}

// amount (human USDC) -> base-unit decimal string for Circle abiParameters.
function toBaseUnits(amount: number): string {
  return BigInt(Math.round(amount * 10 ** USDC_DECIMALS)).toString()
}

export function useInvoiceCirclePay() {
  const [step, setStep] = useState<string | null>(null)

  // Returns { needsSignin: true } when there is no live Circle session, so the
  // caller can redirect to /signin?returnTo=<invoice>. Otherwise runs the pay.
  //
  // memoRef is the invoice's DB ref; it becomes the on-chain invoiceId as
  // keccak256(toHex(memoRef)) so the vault's invoicePaid guard blocks a
  // double-pay and it matches the EOA rail exactly.
  async function payWithCircle(
    to: string,
    usdcAmount: number,
    memoRef: string,
  ): Promise<{ needsSignin: true } | { needsSignin: false; result: CirclePayResult }> {
    if (!hasCircleSession()) return { needsSignin: true }

    const vault     = CONTRACTS.AFRIFX_VAULT
    const amountStr = toBaseUnits(usdcAmount)
    const invoiceId = keccak256(toHex(memoRef))

    try {
      // 1. Approve the vault to pull exactly this amount of USDC.
      await executeContractCall(
        {
          chainKey:             ARC_CHAIN_KEY,
          contractAddress:      CONTRACTS.USDC,
          abiFunctionSignature: 'approve(address,uint256)',
          abiParameters:        [vault, amountStr],
        },
        (m) => setStep(m),
      )

      // 2. Pay the invoice through the vault (fee split happens on-chain).
      const result = await executeContractCall(
        {
          chainKey:             ARC_CHAIN_KEY,
          contractAddress:      vault,
          abiFunctionSignature: 'payInvoice(bytes32,address,uint256)',
          abiParameters:        [invoiceId, to, amountStr],
        },
        (m) => setStep(m),
      )

      return { needsSignin: false, result }
    } catch (e) {
      if (e instanceof NeedsReauthError) return { needsSignin: true }
      throw e
    } finally {
      setStep(null)
    }
  }

  return { payWithCircle, step }
}
