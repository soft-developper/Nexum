// Platform wallet used to call owner-only vault functions on-chain
// (releaseP2POffer, cancelP2POffer, reopenP2POffer, withdrawFees).
// Private key stored in .env never committed to git.
// This wallet must be the contract owner (deployer wallet).

import { createWalletClient, createPublicClient, http, encodeFunctionData } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { arcTestnet, arcClient } from './arc'

const PRIVATE_KEY   = process.env.PLATFORM_WALLET_PRIVATE_KEY as `0x${string}`
const VAULT_ADDRESS = (process.env.NEXUM_VAULT_ADDRESS || process.env.AFRIFX_VAULT_ADDRESS) as `0x${string}`

// FeeProtocol enum order MUST match NexumVault.sol: { P2P = 0, Invoice = 1 }.
export enum FeeProtocol {
  P2P     = 0,
  Invoice = 1,
}

// Vault ABI: owner-only writes we sign here, plus the fee-accounting reads
// the admin dashboard needs. payInvoice is NOT signed by the platform wallet
// (the payer signs it), but its shape is kept here as the single source of
// truth for the vault interface used by the API.
const VAULT_ABI = [
  {
    type: 'function',
    name: 'releaseP2POffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'cancelP2POffer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'offerId', type: 'bytes32' },
      { name: 'reason',  type: 'string'  },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'reopenP2POffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'withdrawFees',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'protocol', type: 'uint8'   },
      { name: 'to',       type: 'address' },
      { name: 'amount',   type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'payInvoice',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'invoiceId', type: 'bytes32' },
      { name: 'creator',   type: 'address' },
      { name: 'amount',    type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'feesAvailable',
    stateMutability: 'view',
    inputs: [{ name: 'protocol', type: 'uint8' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'totalFeesAvailable',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'feesAccrued',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'uint8' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'feesWithdrawn',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'uint8' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

function requireVault(): `0x${string}` {
  if (!VAULT_ADDRESS) {
    throw new Error('Vault address not set: set NEXUM_VAULT_ADDRESS (or legacy AFRIFX_VAULT_ADDRESS) in .env')
  }
  return VAULT_ADDRESS
}

function getWalletClient() {
  if (!PRIVATE_KEY) throw new Error('PLATFORM_WALLET_PRIVATE_KEY not set in .env')
  const account = privateKeyToAccount(PRIVATE_KEY)
  return createWalletClient({
    account,
    chain:     arcTestnet,
    transport: http(process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'),
  })
}

/**
 * Release USDC to taker called automatically when both sides confirm.
 * Taker receives usdcAmount - fee; the fee stays in the vault (inclusive model).
 */
export async function releasePlatform(offerId: `0x${string}`): Promise<`0x${string}`> {
  const vault  = requireVault()
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      vault,
    abi:          VAULT_ABI,
    functionName: 'releaseP2POffer',
    args:         [offerId],
  })

  console.log(`[Platform] Released offer ${offerId} · tx: ${hash}`)
  return hash
}

/**
 * Cancel offer and return the FULL escrow to maker used for disputes.
 * No fee is taken on a cancel.
 */
export async function cancelPlatform(
  offerId: `0x${string}`,
  reason:  string,
): Promise<`0x${string}`> {
  const vault  = requireVault()
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      vault,
    abi:          VAULT_ABI,
    functionName: 'cancelP2POffer',
    args:         [offerId, reason],
  })

  console.log(`[Platform] Cancelled offer ${offerId} · reason: ${reason} · tx: ${hash}`)
  return hash
}

/**
 * Reopen a timed-out accepted offer back to the marketplace.
 * Keeps the USDC escrowed in place (no transfer), clears taker + both
 * confirmations, sets status back to Open. Used by the taker-timeout path
 * INSTEAD of cancelPlatform, so the offer can be taken by someone else.
 */
export async function reopenPlatform(offerId: `0x${string}`): Promise<`0x${string}`> {
  const vault  = requireVault()
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      vault,
    abi:          VAULT_ABI,
    functionName: 'reopenP2POffer',
    args:         [offerId],
  })

  console.log(`[Platform] Reopened offer ${offerId} · tx: ${hash}`)
  return hash
}

/**
 * Withdraw collected platform fees for one protocol (owner only).
 * Bounded on-chain to feesAvailable(protocol): can never touch user escrow.
 * amount is in USDC base units (6 decimals) as a bigint.
 */
export async function withdrawFeesPlatform(
  protocol: FeeProtocol,
  to:       `0x${string}`,
  amount:   bigint,
): Promise<`0x${string}`> {
  const vault  = requireVault()
  const wallet = getWalletClient()

  const hash = await wallet.writeContract({
    address:      vault,
    abi:          VAULT_ABI,
    functionName: 'withdrawFees',
    args:         [protocol, to, amount],
  })

  console.log(`[Platform] Withdrew fees protocol=${protocol} to=${to} amount=${amount} · tx: ${hash}`)
  return hash
}

/**
 * Read the fees still available to withdraw for one protocol (base units).
 */
export async function readFeesAvailable(protocol: FeeProtocol): Promise<bigint> {
  const vault = requireVault()
  return arcClient.readContract({
    address:      vault,
    abi:          VAULT_ABI,
    functionName: 'feesAvailable',
    args:         [protocol],
  }) as Promise<bigint>
}

/**
 * Read per-protocol lifetime accrued + withdrawn + currently-available fees.
 * Everything in USDC base units (6 decimals).
 */
export async function readFeeSummary(protocol: FeeProtocol): Promise<{
  accrued:   bigint
  withdrawn: bigint
  available: bigint
}> {
  const vault = requireVault()
  const [accrued, withdrawn, available] = await Promise.all([
    arcClient.readContract({
      address: vault, abi: VAULT_ABI, functionName: 'feesAccrued',   args: [protocol],
    }) as Promise<bigint>,
    arcClient.readContract({
      address: vault, abi: VAULT_ABI, functionName: 'feesWithdrawn', args: [protocol],
    }) as Promise<bigint>,
    arcClient.readContract({
      address: vault, abi: VAULT_ABI, functionName: 'feesAvailable', args: [protocol],
    }) as Promise<bigint>,
  ])
  return { accrued, withdrawn, available }
}

/**
 * Read total fees available across all protocols (base units).
 */
export async function readTotalFeesAvailable(): Promise<bigint> {
  const vault = requireVault()
  return arcClient.readContract({
    address:      vault,
    abi:          VAULT_ABI,
    functionName: 'totalFeesAvailable',
    args:         [],
  }) as Promise<bigint>
}

export { VAULT_ABI }
