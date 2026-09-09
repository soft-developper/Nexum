import { ethers } from 'hardhat'

// Arc Testnet USDC (6 decimals, native gas token)
const USDC_ADDRESS = '0x3600000000000000000000000000000000000000'
// Arc Testnet CCTP V2 TokenMessenger (from nexum-web/lib/cctp-chains.ts).
// Override via env if it ever changes.
const TOKEN_MESSENGER = process.env.ARC_TOKEN_MESSENGER || '0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA'

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('\nDeploying Nexum contracts to Arc Testnet')
  console.log('    Deployer:', deployer.address)
  console.log('    Chain ID: 5042002\n')

  // Deploy NexumVault (v2.1: P2P + invoice + bridge fees, reopen, accounting)
  const Vault = await ethers.getContractFactory('NexumVault')
  const vault = await Vault.deploy(USDC_ADDRESS)
  await vault.waitForDeployment()
  const vaultAddr = await vault.getAddress()
  console.log('NexumVault deployed:', vaultAddr)

  // Wire the CCTP TokenMessenger so bridgeWithFee works.
  const tx = await vault.setTokenMessenger(TOKEN_MESSENGER)
  await tx.wait()
  console.log('TokenMessenger set:', TOKEN_MESSENGER)

  console.log('\nUpdate these in nexum-web/lib/contracts.ts env:')
  console.log(`    NEXT_PUBLIC_NEXUM_VAULT: '${vaultAddr}'`)

  console.log('\nUpdate in nexum-api/.env:')
  console.log(`    NEXUM_VAULT_ADDRESS=${vaultAddr}`)

  console.log('\nView on ArcScan:')
  console.log(`    https://testnet.arcscan.app/address/${vaultAddr}`)
}

main().catch((err) => { console.error(err); process.exit(1) })
