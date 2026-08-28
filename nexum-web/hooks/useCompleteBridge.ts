'use client'
// ============================================================
// useCompleteBridge — finish a mint that was left outstanding.
//
// WHY THIS EXISTS
// A CCTP bridge burns on the source chain, then mints on the destination. The
// mint is a SEPARATE transaction, so anything that interrupts the flow (closing
// the tab, a slow attestation) leaves the burn done and the mint owed.
//
// Our reconciler can SEE those but cannot fix them: the platform holds no key,
// by design. So the owner of the funds finishes it themselves. That is what
// this does.
//
// __NEXUM_REATTEST_RETRY__ (part4) CCTP makes this safe and permanent:
//   * an attestation can only mint until its expirationBlock (~24h out); past
//     that we call reattest(nonce) for a fresh one - there is NO deadline on
//     requesting re-attestation, because the burn still exists on-chain
//   * minting is idempotent: a reused nonce reverts, it never double-mints
//   * destinationCaller was bytes32(0) at burn time, so ANY address may mint
// A stranded transfer is always recoverable, needing only the original burn
// transaction hash, which we persisted.
//
// CIRCLE MIGRATION: the mint is a contractExecution challenge the user approves
// on their device (executeContractCall), signed by their Circle wallet on the
// destination chain. No wagmi, no network switch — Circle runs the call on the
// chain we name.
// ============================================================

import { useState, useCallback } from 'react'
import {
  executeContractCall, NeedsReauthError, NeedsChainError,
} from '@/hooks/useCircleTx'
import { irisBase, chainByKey, cctpContracts } from '@/lib/cctp-chains'
import { fetchAttestation, reattest } from '@/lib/cctp-client'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export type CompleteStep = 'idle' | 'checking' | 'reattesting' | 'minting' | 'done' | 'error'

export function useCompleteBridge() {
  const [step,   setStep]   = useState<CompleteStep>('idle')
  const [error,  setError]  = useState<string | null>(null)
  const [errorId, setErrorId] = useState<string | null>(null)
  const [mintTx, setMintTx] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [note,   setNote]   = useState<string | null>(null)

  const reset = useCallback(() => {
    setStep('idle'); setError(null); setErrorId(null); setMintTx(null); setBusyId(null); setNote(null)
  }, [])

  const complete = useCallback(async (bridge: {
    id: string
    from_chain: string
    to_chain: string
    burn_tx?: string | null
  }) => {
    if (!bridge.burn_tx) {
      setStep('error'); setError('No burn transaction recorded for this transfer.'); setErrorId(bridge.id)
      return
    }

    setBusyId(bridge.id)
    setStep('checking'); setError(null); setErrorId(null); setNote(null)

    try {
      const from = chainByKey(bridge.from_chain)
      const to   = chainByKey(bridge.to_chain)
      if (!from || !to) throw new Error('Unsupported route')

      // 1. Fetch the attestation using the ORIGINAL burn tx. Attestations never
      //    expire, so this works however long ago the burn happened.
      const att = await fetchAttestation(irisBase(), from.domain, bridge.burn_tx)

      if (att.status === 'not_found') {
        throw new Error(
          'Circle has no record of this burn yet. If it was very recent, wait a ' +
          'few minutes and try again.')
      }
      if (att.status !== 'complete' || !att.message || !att.attestation) {
        throw new Error(
          `Circle has not finished attesting this transfer yet. ${from.name} ` +
          'transfers can take 13 to 19 minutes to finalise. Try again shortly.')
      }

      await fetch(`${API}/bridge/${bridge.id}/attested`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ attestation: att.attestation }),
      }).catch(() => {})

      // 2. Mint on the destination chain, retrying through re-attestation.
      //
      // A stranded transfer can fail to mint for a documented, recoverable
      // reason: the attestation's 24h expirationBlock has passed. Circle's fix
      // is reattest(nonce) -> re-poll -> re-mint. We attempt the mint, and on a
      // failure that isn't 'already minted' or an auth/chain prompt, we run ONE
      // reattest cycle before surfacing an error. Minting is idempotent, so a
      // retry can never double-mint.
      const recordCompleted = async (tx: string) => {
        await fetch(`${API}/bridge/${bridge.id}/completed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mintTx: tx }),
        }).catch(() => {})
      }

      const doMint = async (message: string, attestation: string) => {
        setStep('minting')
        const result = await executeContractCall({
          chainKey:             to.key,
          contractAddress:      cctpContracts().messageTransmitter,
          abiFunctionSignature: 'receiveMessage(bytes,bytes)',
          abiParameters:        [message, attestation],
        }, setNote)
        return result.txHash ?? 'pending'
      }

      let currentAtt = att
      try {
        const tx = await doMint(currentAtt.message!, currentAtt.attestation!)
        await recordCompleted(tx)
        setMintTx(tx); setStep('done'); setNote(null)
      } catch (mintErr: any) {
        // __NEXUM_MINT_RETRY_FIX__ distinguish a submission failure (valid
        // attestation, mint call itself failed) from a genuinely expired
        // attestation. Only the latter is helped by reattestation.
        const m = mintErr?.message ?? ''

        // Idempotent success: the mint already landed.
        if (/already been used|nonce already|already minted|already been processed/i.test(m)) {
          await recordCompleted('already-minted')
          setMintTx('already-minted'); setStep('done'); setNote(null)
          return
        }
        // Auth / chain prompts are for the caller to resolve, not retryable here.
        if (mintErr instanceof NeedsReauthError || mintErr instanceof NeedsChainError) {
          throw mintErr
        }

        // Is the attestation ACTUALLY expired, or is it still valid and the mint
        // submission itself failed? Re-fetch and check. If Circle still returns
        // it as complete, reattesting is pointless - the real problem is the
        // mint call (gas on the destination, wrong contract, or a Circle-side
        // rejection), and we must surface THAT error, not hide it behind a
        // reattest that can never help.
        setNote('Checking whether the attestation is still valid...')
        const recheck = await fetchAttestation(irisBase(), from.domain, bridge.burn_tx!)
        const stillValid =
          recheck.status === 'complete' && !!recheck.message && !!recheck.attestation

        if (stillValid) {
          // The message is mint-ready; the failure is in submission. Surface
          // Circle's real error so it is diagnosable instead of misreported.
          console.error('[bridge] mint failed with a VALID attestation:', mintErr)
          throw new Error(
            'The transfer is attested and ready, but the mint could not be ' +
            'submitted on ' + to.name + '. This is usually gas on the ' +
            'destination or a temporary Circle issue - your funds are safe. ' +
            'Details: ' + (m || 'unknown error'))
        }

        // Genuinely not complete anymore -> the attestation expired. NOW a
        // reattest cycle is the correct remedy.
        const nonce = currentAtt.nonce ?? currentAtt.eventNonce
        if (!nonce) throw mintErr

        setStep('reattesting')
        setNote('The attestation expired - requesting a fresh one from Circle...')
        const ok = await reattest(irisBase(), nonce)
        if (!ok) {
          throw new Error(
            'The attestation for this transfer expired and re-attestation could ' +
            'not be requested right now. Your funds are safe - try again shortly.')
        }

        // Re-poll for the refreshed attestation (a few gentle attempts).
        setNote('Waiting for the refreshed attestation...')
        let refreshed = null as typeof currentAtt | null
        for (let i = 0; i < 6; i++) {
          await new Promise(r => setTimeout(r, 5000))
          const again = await fetchAttestation(irisBase(), from.domain, bridge.burn_tx!)
          if (again.status === 'complete' && again.message && again.attestation) {
            refreshed = again
            break
          }
        }
        if (!refreshed) {
          throw new Error(
            'Requested a fresh attestation, but it is not ready yet. Your funds ' +
            'are safe - come back in a few minutes and press Complete again.')
        }

        await fetch(`${API}/bridge/${bridge.id}/attested`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ attestation: refreshed.attestation }),
        }).catch(() => {})

        // Second and final mint attempt with the fresh attestation.
        const tx2 = await doMint(refreshed.message!, refreshed.attestation!)
        await recordCompleted(tx2)
        setMintTx(tx2); setStep('done'); setNote(null)
      }
    } catch (err: any) {
      let message = err?.message ?? 'Could not complete the transfer'
      if (err instanceof NeedsReauthError || err instanceof NeedsChainError) {
        message = err.message
      } else if (/already been used|nonce already|already minted|already been processed/i.test(message)) {
        // The mint already happened, so this is success, not failure.
        message = 'This transfer was already completed. Refreshing the list.'
        await fetch(`${API}/bridge/${bridge.id}/completed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mintTx: 'already-minted' }),
        }).catch(() => {})
      }
      setStep('error'); setError(message); setErrorId(bridge.id); setNote(null)
    } finally {
      setBusyId(null)
    }
  }, [])

  return { step, error, errorId, mintTx, busyId, note, complete, reset }
}
