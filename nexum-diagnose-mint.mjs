#!/usr/bin/env node
/* ============================================================================
 * nexum-diagnose-mint.mjs - why is a stranded CCTP mint failing?
 *
 * Read-only. Queries Circle's get-messages-v2 for your burn tx and prints the
 * decoded message + a verdict on whether (and how) the mint can proceed. It
 * changes NOTHING - not your repo, not the chain, not Circle.
 *
 * USAGE (from anywhere; needs only Node 18+ for global fetch):
 *   node nexum-diagnose-mint.mjs <burnTxHash> <sourceChainKey> [--mainnet] [--your-address 0x..]
 *
 * examples:
 *   node nexum-diagnose-mint.mjs 0xabc...def base
 *   node nexum-diagnose-mint.mjs 0xabc...def ethereum --mainnet --your-address 0xYourWallet
 *
 * sourceChainKey is the chain you bridged FROM: one of
 *   arc base ethereum arbitrum polygon optimism avalanche unichain monad
 * Pass --mainnet if this was a mainnet bridge (default is testnet/sandbox).
 * Pass --your-address to check whether a destinationCaller restriction would
 * block YOUR wallet specifically.
 * ========================================================================== */

const DOMAIN = {
  ethereum: 0, avalanche: 1, optimism: 2, arbitrum: 3,
  base: 6, polygon: 7, unichain: 10, monad: 15, arc: 26,
}

const args = process.argv.slice(2)
const positional = args.filter(a => !a.startsWith('--'))
const burnTx = positional[0]
const chainKey = positional[1]
const isMainnet = args.includes('--mainnet')
const yourAddrFlag = args.indexOf('--your-address')
const yourAddress = yourAddrFlag !== -1 ? (args[yourAddrFlag + 1] || '').toLowerCase() : null

function die(msg) { console.error(`\n  ERROR: ${msg}\n`); process.exit(1) }

if (!burnTx || !chainKey) {
  die('Usage: node nexum-diagnose-mint.mjs <burnTxHash> <sourceChainKey> [--mainnet] [--your-address 0x..]')
}
if (!/^0x[a-fA-F0-9]{64}$/.test(burnTx)) die(`"${burnTx}" is not a valid 0x tx hash (need 66 chars).`)
const domain = DOMAIN[chainKey]
if (domain === undefined) die(`Unknown source chain "${chainKey}". Use one of: ${Object.keys(DOMAIN).join(', ')}`)

const irisBase = isMainnet ? 'https://iris-api.circle.com' : 'https://iris-api-sandbox.circle.com'
const ZERO = '0x0000000000000000000000000000000000000000'

const bar = (s = '') => console.log('  ' + '-'.repeat(64) + (s ? `\n  ${s}` : ''))
const line = (k, v) => console.log(`  ${(k + ':').padEnd(22)} ${v}`)

;(async () => {
  console.log(`\n  CCTP mint diagnosis`)
  bar()
  line('burn tx', burnTx)
  line('source chain', `${chainKey} (domain ${domain})`)
  line('environment', isMainnet ? 'MAINNET (iris-api)' : 'testnet (iris-api-sandbox)')
  line('iris endpoint', irisBase)
  bar()

  const url = `${irisBase}/v2/messages/${domain}?transactionHash=${burnTx}`
  let res, data
  try {
    res = await fetch(url)
  } catch (e) {
    die(`Could not reach Circle (${e.message}). Check network / try again.`)
  }

  if (res.status === 404) {
    console.log(`\n  VERDICT: Circle has NO record of this burn (404).`)
    console.log(`  -> Either the hash/chain is wrong, or the burn is very recent and`)
    console.log(`     not yet indexed. If it truly never appears, the burn may not have`)
    console.log(`     emitted a CCTP message (wrong contract on source?).\n`)
    process.exit(0)
  }
  if (res.status === 429) die('Circle rate-limited this check (429). Wait ~5 min and retry.')
  if (!res.ok) die(`Circle returned HTTP ${res.status}. Body: ${await res.text().catch(() => '')}`)

  data = await res.json().catch(() => ({}))
  const messages = data?.messages ?? []
  if (!messages.length) {
    console.log(`\n  VERDICT: response had no messages. Raw:\n`)
    console.log(JSON.stringify(data, null, 2))
    process.exit(0)
  }

  console.log(`  Found ${messages.length} message(s) for this burn.\n`)

  messages.forEach((m, i) => {
    bar(`MESSAGE #${i + 1}`)
    const dm = m.decodedMessage ?? {}
    const body = dm.decodedMessageBody ?? {}
    line('status', m.status)                       // complete | pending_confirmations
    line('cctpVersion', m.cctpVersion)
    line('eventNonce', m.eventNonce ?? '(none)')
    line('has attestation', m.attestation && m.attestation !== 'PENDING' ? 'YES' : 'NO / PENDING')
    line('has message bytes', m.message && m.message !== '0x' ? 'YES' : 'NO (0x)')
    if (m.delayReason) line('*** delayReason', m.delayReason)
    console.log('')
    line('sourceDomain', dm.sourceDomain ?? '?')
    line('destinationDomain', dm.destinationDomain ?? '?')
    line('mintRecipient', body.mintRecipient ?? '?')
    line('destinationCaller', dm.destinationCaller ?? '?')
    line('amount', body.amount ?? '?')
    if (body.maxFee !== undefined)     line('maxFee', body.maxFee)
    if (body.feeExecuted !== undefined) line('feeExecuted', body.feeExecuted)
    if (body.expirationBlock !== undefined) line('expirationBlock', body.expirationBlock)
    console.log('')

    // ---- verdict per message ----
    const problems = []
    const notes = []

    if (m.status !== 'complete') {
      problems.push(`Attestation is "${m.status}", not "complete" - the mint CANNOT be`)
      problems.push(`  submitted yet. It only becomes mintable once status is "complete".`)
      if (m.delayReason === 'insufficient_fee') {
        problems.push(`  CAUSE: delayReason=insufficient_fee - the Fast-Transfer maxFee was`)
        problems.push(`  too low, so Circle will not fast-attest. It may still finalise at`)
        problems.push(`  standard speed; otherwise this transfer needed a higher maxFee.`)
      } else if (m.delayReason) {
        problems.push(`  CAUSE: delayReason=${m.delayReason}.`)
      }
    }

    const dc = (dm.destinationCaller ?? '').toLowerCase()
    const dcRestricted = dc && dc !== ZERO && !/^0x0+$/.test(dc.replace('0x',''))
    if (dcRestricted) {
      problems.push(`destinationCaller is RESTRICTED to ${dm.destinationCaller}.`)
      problems.push(`  Only THAT address can submit receiveMessage - any other caller reverts.`)
      if (yourAddress) {
        if (dc.endsWith(yourAddress.replace('0x', ''))) {
          notes.push(`Your address matches the destinationCaller - you can mint, so the`)
          notes.push(`  failure is elsewhere (gas, contract address, or the call build).`)
        } else {
          problems.push(`  Your wallet (${yourAddress}) does NOT match - it can never mint this.`)
        }
      } else {
        notes.push(`Pass --your-address 0x.. to check if YOUR wallet is the allowed caller.`)
      }
    } else {
      notes.push(`destinationCaller is zero - ANY address may mint (good).`)
    }

    if (m.status === 'complete' && !dcRestricted) {
      notes.push(`This message IS mint-ready (status complete, open caller). If your mint`)
      notes.push(`  still fails with NO tx hash, the failure is BEFORE submission:`)
      notes.push(`  - destination MessageTransmitterV2 address wrong for target chain, or`)
      notes.push(`  - Circle wallet could not build/estimate the call (gas on dest chain), or`)
      notes.push(`  - message/attestation not passed through exactly as returned.`)
    }

    if (problems.length) {
      console.log('  >>> LIKELY BLOCKER:')
      problems.forEach(p => console.log('  ' + p))
    }
    if (notes.length) {
      console.log(problems.length ? '\n  Notes:' : '  >>> STATUS:')
      notes.forEach(n => console.log('  ' + n))
    }
    console.log('')
  })

  bar('RAW decodedMessage (for reference)')
  console.log(JSON.stringify(messages.map(m => m.decodedMessage), null, 2))
  console.log('')
})()
