// Shared platform-fee constants for the frontend fee breakdowns.
// Mirrors NexumVault.sol: p2pFeeBps = invoiceFeeBps = 10 (0.10%).
// Uniform INCLUSIVE model: the recipient nets (amount - fee); the fee is
// deducted from the amount, not added on top.
//
// If the on-chain bps ever changes (setP2PFeeBps / setInvoiceFeeBps), update
// this to match, or wire it from an API/chain read. Kept as a constant here so
// the UI has a single source of truth instead of scattering 0.001 literals.

export const PLATFORM_FEE_BPS = 10          // 10 bps = 0.10%
export const PLATFORM_FEE_RATE = PLATFORM_FEE_BPS / 10_000 // 0.001
export const PLATFORM_FEE_LABEL = '0.1%'

// Fee taken out of a USDC amount (inclusive model). Returns fee + net payout.
export function platformFee(amount: number): { fee: number; net: number } {
  if (!Number.isFinite(amount) || amount <= 0) return { fee: 0, net: 0 }
  const fee = amount * PLATFORM_FEE_RATE
  return { fee, net: amount - fee }
}
