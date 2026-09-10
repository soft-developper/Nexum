import { ethers } from 'hardhat'

/*
  Isolate WHY bridgeWithFee reverts, by simulating it against the LIVE vault and
  decoding the revert reason (the browser only shows "execution reverted").

  It runs three probes, each independent, so we learn exactly which step fails:
    A. usdc.allowance(caller, vault)      - is the vault actually approved?
    B. staticCall bridgeWithFee(...)      - decodes the vault/CCTP revert reason
    C. a direct staticCall of depositForBurn from the caller (control) - tells us
       whether the SAME args work when called directly (isolates vault vs CCTP)

  Usage (fill the 3 env vars with a REAL past attempt's values):
    NEXUM_VAULT_ADDRESS=0x7F3a...61ED \
    BRIDGE_AMOUNT=1000000 \                # gross, 6dp (e.g. 1 USDC = 1000000)
    DEST_DOMAIN=6 \                        # CCTP domain of the destination
    npx hardhat run scripts/diagnose-bridge.ts --network arc_testnet

  The signer (from PRIVATE_KEY/DEPLOYER in your hardhat config) is treated as the
  bridging user. Use the wallet you actually bridged from so the allowance check
  is meaningful.
*/

const USDC = '0x3600000000000000000000000000000000000000'
const MESSENGER = '0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA'

const VAULT_ABI = [
  'function bridgeWithFee(uint256 amount,uint32 destinationDomain,bytes32 mintRecipient,uint256 maxFee,uint32 minFinalityThreshold) returns (uint64)',
  'function tokenMessenger() view returns (address)',
  'function bridgeFeeBps() view returns (uint256)',
  'function paused() view returns (bool)',
]
const USDC_ABI = [
  'function allowance(address owner,address spender) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
]
const MESSENGER_ABI = [
  'function depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32) returns (uint64)',
]

function addressToBytes32(addr: string): string {
  return '0x' + '0'.repeat(24) + addr.toLowerCase().replace(/^0x/, '')
}

async function main() {
  const vaultAddr = process.env.NEXUM_VAULT_ADDRESS
  const amount    = BigInt(process.env.BRIDGE_AMOUNT || '1000000')
  const destDom   = Number(process.env.DEST_DOMAIN || '0')
  if (!vaultAddr) { console.error('Set NEXUM_VAULT_ADDRESS'); process.exit(1) }

  const [signer] = await ethers.getSigners()
  const me = signer.address
  console.log('\nDiagnosing bridgeWithFee')
  console.log('  caller (you):', me)
  console.log('  vault:       ', vaultAddr)
  console.log('  amount:      ', amount.toString(), '(6dp)')
  console.log('  destDomain:  ', destDom, '\n')

  const vault = new ethers.Contract(vaultAddr, VAULT_ABI, signer)
  const usdc  = new ethers.Contract(USDC, USDC_ABI, signer)
  const messenger = new ethers.Contract(MESSENGER, MESSENGER_ABI, signer)

  // ---- A. allowance + balance ----
  const [allow, bal, feeBps, paused, msgr] = await Promise.all([
    usdc.allowance(me, vaultAddr), usdc.balanceOf(me),
    vault.bridgeFeeBps(), vault.paused(), vault.tokenMessenger(),
  ])
  console.log('A. allowance(you -> vault):', allow.toString(), allow >= amount ? '(enough)' : '(TOO LOW - approve first!)')
  console.log('   your USDC balance:      ', bal.toString(), bal >= amount ? '(enough)' : '(TOO LOW)')
  console.log('   vault.tokenMessenger:   ', msgr, msgr.toLowerCase() === MESSENGER.toLowerCase() ? '(correct)' : '(UNEXPECTED)')
  console.log('   vault.paused:           ', paused)
  console.log('   vault.bridgeFeeBps:     ', feeBps.toString())

  const fee = (amount * BigInt(feeBps)) / 10000n
  const net = amount - fee
  const maxFee = 0n // standard transfer -> standard fee is 0, maxFee 0 is valid
  const finality = 2000 // Arc requires 2000 (finalized)
  const mintRecipient = addressToBytes32(me)

  // ---- B. simulate bridgeWithFee (decodes the real revert) ----
  console.log('\nB. staticCall vault.bridgeWithFee(net-burn, maxFee=0, finality=2000)...')
  try {
    await vault.bridgeWithFee.staticCall(amount, destDom, mintRecipient, maxFee, finality)
    console.log('   -> would SUCCEED (no revert). If the live app still fails, the')
    console.log('      difference is the maxFee/finality the FRONTEND sends; compare them.')
  } catch (e: any) {
    console.log('   -> REVERTED:', e.reason ?? e.shortMessage ?? e.message)
    if (e.data) console.log('      raw data:', e.data)
  }

  // ---- C. control: direct depositForBurn from you (bypass vault) ----
  console.log('\nC. control: staticCall messenger.depositForBurn directly (net, maxFee=0, finality=2000)...')
  try {
    await messenger.depositForBurn.staticCall(net, destDom, mintRecipient, USDC, '0x' + '0'.repeat(64), maxFee, finality)
    console.log('   -> direct depositForBurn would SUCCEED. So the burn args are fine;')
    console.log('      the vault-specific revert (B) is the vault path (allowance/transferFrom).')
  } catch (e: any) {
    console.log('   -> direct depositForBurn REVERTED:', e.reason ?? e.shortMessage ?? e.message)
    console.log('      => the burn ARGS themselves are rejected by CCTP (maxFee/finality/domain).')
    if (e.data) console.log('      raw data:', e.data)
  }

  console.log('\nRead B and C together:')
  console.log('  - B reverts, C succeeds  -> vault path issue (allowance/transferFrom/approve).')
  console.log('  - B and C both revert    -> CCTP rejects the args (maxFee/finality/domain).')
  console.log('  - both succeed           -> the live frontend sends different maxFee/finality;')
  console.log('                              fix is to send maxFee=0 + finality=2000 for Arc.\n')
}

main().catch((e) => { console.error(e); process.exit(1) })
