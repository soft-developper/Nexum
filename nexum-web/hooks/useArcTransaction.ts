'use client'
import { ARC_EXPLORER } from '@/lib/contracts'
import { useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { arcTestnet } from '@/lib/arc-chain'

/**
 * Poll for a transaction receipt on Arc.
 * Arc has sub-second finality so this resolves almost immediately.
 */
export function useArcTransaction(hash?: `0x${string}`) {
  const { data, isLoading, isSuccess, isError } = useWaitForTransactionReceipt({
    hash,
    chainId: arcTestnet.id,
  })

  return {
    receipt: data,
    isLoading,
    isSuccess,
    isError,
    explorerUrl: hash
      ? `${ARC_EXPLORER}/tx/${hash}`
      : null,
  }
}

// __NEXUM_MAINNET_M5__ 20260924-002419
