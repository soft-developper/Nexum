import { ethers } from 'hardhat'

// Post-deploy sanity check for a freshly deployed NexumVault.
// Reads the on-chain state and asserts it matches what v2 expects, so you
// confirm the new vault is healthy BEFORE flipping production env vars to it.
//
// Usage:
//   NEXUM_VAULT_ADDRESS=0x<new-vault> npx hardhat run scripts/verify-deploy.ts --network arc_testnet
//
// Exits non-zero if any check fails.

const USDC_ADDRESS = '0x3600000000000000000000000000000000000000'

const ABI = [
  'function usdc() view returns (address)',
  'function owner() view returns (address)',
  'function p2pFeeBps() view returns (uint256)',
  'function invoiceFeeBps() view returns (uint256)',
  'function bridgeFeeBps() view returns (uint256)',
  'function tokenMessenger() view returns (address)',
  'function spreadBps() view returns (uint256)',
  'function paused() view returns (bool)',
  'function feesAccrued(uint8) view returns (uint256)',
  'function totalFeesAvailable() view returns (uint256)',
]

async function main() {
  const addr = process.env.NEXUM_VAULT_ADDRESS
  if (!addr) {
    console.error('Set NEXUM_VAULT_ADDRESS=0x<new-vault> before running.')
    process.exit(1)
  }

  const [signer] = await ethers.getSigners()
  const vault = new ethers.Contract(addr, ABI, signer)

  console.log('\nVerifying NexumVault at', addr, '\n')

  const checks: { label: string; got: string; want: string; ok: boolean }[] = []
  const rec = (label: string, got: any, want: any, ok: boolean) =>
    checks.push({ label, got: String(got), want: String(want), ok })

  // 1. USDC wired correctly
  const usdc = await vault.usdc()
  rec('usdc()', usdc, USDC_ADDRESS, usdc.toLowerCase() === USDC_ADDRESS.toLowerCase())

  // 2. Owner is the deployer (who holds PLATFORM_WALLET_PRIVATE_KEY / signs owner calls)
  const owner = await vault.owner()
  rec('owner()', owner, signer.address + ' (deployer)', owner.toLowerCase() === signer.address.toLowerCase())

  // 3. Fees default to 10 bps (0.10%)
  const p2pBps = await vault.p2pFeeBps()
  rec('p2pFeeBps()', p2pBps, 10, Number(p2pBps) === 10)

  const invBps = await vault.invoiceFeeBps()
  rec('invoiceFeeBps()', invBps, 10, Number(invBps) === 10)

  const brBps = await vault.bridgeFeeBps()
  rec('bridgeFeeBps()', brBps, 10, Number(brBps) === 10)

  // Bridge needs the CCTP TokenMessenger wired, or bridgeWithFee reverts.
  const messenger = await vault.tokenMessenger()
  const ZERO = '0x0000000000000000000000000000000000000000'
  rec('tokenMessenger() set', messenger, 'non-zero (CCTP messenger)', messenger !== ZERO)

  // 4. Not paused (ready to take offers)
  const paused = await vault.paused()
  rec('paused()', paused, false, paused === false)

  // 5. Fresh vault: no fees accrued yet, nothing available
  const totalAvail = await vault.totalFeesAvailable()
  rec('totalFeesAvailable()', totalAvail, 0, Number(totalAvail) === 0)

  // Report
  let allOk = true
  for (const c of checks) {
    const mark = c.ok ? 'OK ' : 'XX '
    if (!c.ok) allOk = false
    console.log(`  [${mark}] ${c.label}: ${c.got}${c.ok ? '' : `  (expected ${c.want})`}`)
  }

  console.log('')
  if (allOk) {
    console.log('All checks passed. The new vault is healthy.')
    console.log('Next: set NEXT_PUBLIC_NEXUM_VAULT (web) and NEXUM_VAULT_ADDRESS (api) to', addr)
  } else {
    console.log('One or more checks FAILED. Do NOT flip production to this address yet.')
    process.exit(1)
  }
}

main().catch((err) => { console.error(err); process.exit(1) })
