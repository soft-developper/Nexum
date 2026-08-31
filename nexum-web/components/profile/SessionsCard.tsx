'use client'
// __NEXUM_SESSIONS_CARD__
// "Devices & sessions" card. Lists the user's active sessions with a friendly
// device label, last-active time and approximate city, and lets them revoke
// any session. Revoking the CURRENT session signs out locally and redirects to
// /signin (mirrors AccountMenu's sign-out).
import { useState } from 'react'
import { useSessions, useRevokeSession, useRevokeOtherSessions } from '@/hooks/useSessions'
import { clearSession } from '@/hooks/useAuth'
import { clearSigningSession } from '@/hooks/useCircleTx'
import { Button } from '@/components/ui/button'
import { Loader2, Monitor, Smartphone, Tablet, LogOut } from 'lucide-react'

// Best-effort friendly label from a user-agent string.
function deviceLabel(ua: string | null): { label: string; kind: 'mobile' | 'tablet' | 'desktop' } {
  if (!ua) return { label: 'Unknown device', kind: 'desktop' }
  const s = ua.toLowerCase()

  const isTablet = s.includes('ipad') || (s.includes('android') && !s.includes('mobile'))
  const isMobile = !isTablet && (s.includes('mobile') || s.includes('iphone') || s.includes('android'))
  const kind: 'mobile' | 'tablet' | 'desktop' = isTablet ? 'tablet' : isMobile ? 'mobile' : 'desktop'

  const os =
    s.includes('iphone') || s.includes('ipad') || s.includes('ios')     ? 'iOS' :
    s.includes('mac os') || s.includes('macintosh')                     ? 'macOS' :
    s.includes('android')                                              ? 'Android' :
    s.includes('windows')                                             ? 'Windows' :
    s.includes('linux')                                               ? 'Linux' : ''

  const browser =
    s.includes('edg/')                       ? 'Edge' :
    s.includes('chrome') && !s.includes('edg') ? 'Chrome' :
    s.includes('firefox')                    ? 'Firefox' :
    s.includes('safari') && !s.includes('chrome') ? 'Safari' : ''

  const label = [browser, os].filter(Boolean).join(' on ') || 'Unknown device'
  return { label, kind }
}

function relativeTime(ts: number | null): string {
  if (!ts) return 'unknown'
  const secs = Math.max(0, Math.floor(Date.now() / 1000) - ts)
  if (secs < 60)      return 'just now'
  const mins = Math.floor(secs / 60)
  if (mins < 60)      return `${mins} min${mins !== 1 ? 's' : ''} ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24)       return `${hrs} hour${hrs !== 1 ? 's' : ''} ago`
  const days = Math.floor(hrs / 24)
  if (days < 30)      return `${days} day${days !== 1 ? 's' : ''} ago`
  const months = Math.floor(days / 30)
  return `${months} month${months !== 1 ? 's' : ''} ago`
}

export function SessionsCard() {
  const { data: sessions, isLoading } = useSessions()
  const revokeOne    = useRevokeSession()
  const revokeOthers = useRevokeOtherSessions()
  const [busyId, setBusyId] = useState<string | null>(null)

  function signOutLocally() {
    clearSigningSession()
    clearSession()
    window.location.href = '/signin'
  }

  async function handleRevoke(id: string, isCurrent: boolean) {
    setBusyId(id)
    try {
      await revokeOne.mutateAsync(id)
      if (isCurrent) signOutLocally()
    } catch {
      setBusyId(null)
    }
  }

  const hasOthers = (sessions ?? []).some(s => !s.is_current)

  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5">
      <div className="mb-3 flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-app-text">Devices & sessions</p>
          <p className="text-xs text-app-muted">Where you're signed in. Revoke any you don't recognise.</p>
        </div>
        {hasOthers && (
          <Button
            variant="outline" size="sm"
            onClick={() => revokeOthers.mutate()}
            disabled={revokeOthers.isPending}
          >
            {revokeOthers.isPending
              ? <><Loader2 className="h-3.5 w-3.5 animate-spin" /> Working</>
              : <><LogOut className="h-3.5 w-3.5" /> Sign out others</>}
          </Button>
        )}
      </div>

      {isLoading ? (
        <div className="flex h-20 items-center justify-center">
          <Loader2 className="h-5 w-5 animate-spin text-app-muted" />
        </div>
      ) : !sessions || sessions.length === 0 ? (
        <p className="py-4 text-center text-xs text-app-muted">No active sessions found.</p>
      ) : (
        <ul className="space-y-2">
          {sessions.map(s => {
            const { label, kind } = deviceLabel(s.user_agent)
            const Icon = kind === 'mobile' ? Smartphone : kind === 'tablet' ? Tablet : Monitor
            const busy = busyId === s.id && revokeOne.isPending
            return (
              <li key={s.id}
                className="flex items-center gap-3 rounded-lg border border-app-border bg-app-bg px-3 py-2.5">
                <Icon className="h-4 w-4 shrink-0 text-app-muted" />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <p className="truncate text-sm text-app-text">{label}</p>
                    {s.is_current && (
                      <span className="shrink-0 rounded-full bg-app-accent/10 px-2 py-0.5 text-[10px] text-app-accent-text">
                        This device
                      </span>
                    )}
                  </div>
                  <p className="truncate text-xs text-app-muted">
                    {s.location_city ? `${s.location_city} · ` : ''}Active {relativeTime(s.last_active_at)}
                  </p>
                </div>
                <button
                  onClick={() => handleRevoke(s.id, s.is_current)}
                  disabled={busy}
                  className="shrink-0 rounded-md border border-app-border px-2.5 py-1 text-xs text-app-muted transition-colors hover:border-red-900/40 hover:text-red-400 disabled:opacity-50"
                >
                  {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : (s.is_current ? 'Sign out' : 'Revoke')}
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
