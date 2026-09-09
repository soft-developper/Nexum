import { ethers } from 'hardhat'

// Arc Testnet USDC address 6 decimals ERC-20 interface
const USDC_ADDRESS = '0x3600000000000000000000000000000000000000'

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('\nDeploying Nexum contracts to Arc Testnet')
  console.log('    Deployer:', deployer.address)
  console.log('    Chain ID: 5042002\n')

  // Deploy NexumVault (v2: platform fees + reopenP2POffer + fee accounting)
  const Vault = await ethers.getContractFactory('NexumVault')
  const vault = await Vault.deploy(USDC_ADDRESS)
  await vault.waitForDeployment()
  const vaultAddr = await vault.getAddress()
  console.log('NexumVault deployed:', vaultAddr)

  console.log('\nUpdate these in nexum-web/lib/contracts.ts:')
  console.log(`    NEXT_PUBLIC_NEXUM_VAULT: '${vaultAddr}'`)

  console.log('\nUpdate in nexum-api/.env:')
  console.log(`    NEXUM_VAULT_ADDRESS=${vaultAddr}`)

  console.log('\nView on ArcScan:')
  console.log(`    https://testnet.arcscan.app/address/${vaultAddr}`)
}

main().catch((err) => { console.error(err); process.exit(1) })
