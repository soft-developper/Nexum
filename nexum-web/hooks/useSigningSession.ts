'use client'
// ============================================================
// useSigningSession — clean handling of Circle signing-session expiry.
//
// THE PROBLEM THIS SOLVES
// The Circle userToken lasts ~60 min (we expire ours at 55, see useCircleTx),
// but our app session lasts 30 days. So the dashboard can look fully signed in
// while the wallet can no longer sign. Today that mismatch only surfaces when
// the user tries a transaction and gets a "sign in again" error mid-action,
// because components read getSigningSession() imperatively when they act, not
// reactively — nothing re-renders when the token quietly expires.
//
// WHAT THIS DOES
// Watch Circle's OWN expiry timestamp (SigningSession.expiresAt — the real
// live-session config, not a timer we invented). When it passes:
//   1. clear the (now dead) signing session, and
//   2. hard-refresh the app once, so every wallet-gated hook re-reads a clean
//      state and the wallet-live UI switches off.
// The app session stays valid, so the user remains signed into the dashboard —
// the wallet simply goes inactive, and the next action cleanly prompts re-auth
// instead of erroring in the middle of a transfer.
//
// WHAT THIS DOES NOT TOUCH
// The signing flow itself, token TTL, or useIdleSignOut (a separate axis:
// 30-min real inactivity → full sign-out). This only reacts to Circle's
// existing expiry; it never shortens or extends it.
//
// Checked on mount, on tab focus/visibility, and via a timer armed for the
// exact moment the token expires.
// ============================================================
import { useEffect, useRef } from 'react'
import { getSigningSession, clearSigningSession, SIGNING_KEY } from '@/hooks/useCircleTx'

// A tiny grace so the timer fires just AFTER expiry, never a hair before.
const EXPIRY_GRACE_MS = 500

export function useSigningSession() {
  const timer   = useRef<ReturnType<typeof setTimeout> | null>(null)
  const handled = useRef(false)

  useEffect(() => {
    // Reads sessionStorage; guard the raw value so a corrupt entry can't throw.
    function rawExpiry(): number | null {
      const s = getSigningSession()   // returns null if missing OR already expired
      return s ? s.expiresAt : null
    }

    // The wallet session has ended (or was never present in this tab). Clear it
    // and refresh ONCE so wallet-gated UI goes inactive. We only refresh if a
    // session token still physically exists in storage — otherwise a fresh tab
    // that simply never had a signing session would reload pointlessly.
    function handleExpiry() {
      if (handled.current) return
      handled.current = true
      if (timer.current) { clearTimeout(timer.current); timer.current = null }

      // Was there anything to expire? sessionStorage still holds the (now
      // stale) blob even though getSigningSession() returns null once past
      // expiresAt. If nothing is there at all, do nothing — this tab was
      // never signing-enabled, so there's no live UI to reset.
      let hadSession = false
      try { hadSession = !!sessionStorage.getItem(SIGNING_KEY) } catch {}
      clearSigningSession()
      if (hadSession) {
        // Full reload: components read the signing session imperatively, so a
        // hard refresh is the reliable way to switch every wallet-live surface
        // off at once. The app (30-day) session survives the reload.
        window.location.reload()
      }
    }

    // Look at the current expiry and decide: expired now → handle; still live →
    // arm a timer for the exact remaining time.
    function evaluate() {
      if (handled.current) return
      const exp = rawExpiry()

      if (exp === null) {
        // getSigningSession() returns null for BOTH "no session" and "expired".
        // Distinguish: if a stale blob is still in storage, it just expired →
        // handle it. If storage is empty, there's nothing to do.
        let stale = false
        try { stale = !!sessionStorage.getItem(SIGNING_KEY) } catch {}
        if (stale) handleExpiry()
        return
      }

      const remaining = exp - Date.now()
      if (remaining <= 0) { handleExpiry(); return }

      if (timer.current) clearTimeout(timer.current)
      timer.current = setTimeout(handleExpiry, remaining + EXPIRY_GRACE_MS)
    }

    // Re-evaluate when the user returns to the tab: a background tab's timers
    // are throttled, so the token may have expired while it slept.
    const onFocus = () => evaluate()

    window.addEventListener('focus', onFocus)
    document.addEventListener('visibilitychange', onFocus)

    evaluate()

    return () => {
      if (timer.current) clearTimeout(timer.current)
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('visibilitychange', onFocus)
    }
  }, [])
}
