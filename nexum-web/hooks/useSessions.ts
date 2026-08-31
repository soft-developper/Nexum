'use client'
// __NEXUM_USE_SESSIONS__
// Sessions/devices data layer. Reads the caller's live sessions and revokes
// them, all through the authenticated apiFetch (Bearer nexum_token).
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { apiFetch } from '@/hooks/useAuth'

export interface DeviceSession {
  id:             string
  ip_address:     string | null
  user_agent:     string | null
  location_city:  string | null
  created_at:     number
  last_active_at: number | null
  expires_at:     number
  is_current:     boolean
}

export function useSessions() {
  return useQuery<DeviceSession[]>({
    queryKey: ['sessions'],
    queryFn:  async () => {
      const res = await apiFetch('/auth/sessions')
      if (!res.ok) throw new Error('Failed to load sessions')
      const data = await res.json()
      return (data.sessions ?? []) as DeviceSession[]
    },
    staleTime: 30_000,
    retry:     false,
  })
}

export function useRevokeSession() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const res = await apiFetch('/auth/sessions/revoke', {
        method: 'POST',
        body:   JSON.stringify({ id }),
      })
      if (!res.ok) throw new Error('Failed to revoke session')
      return res.json()
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['sessions'] }) },
  })
}

export function useRevokeOtherSessions() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      const res = await apiFetch('/auth/sessions/revoke-others', { method: 'POST' })
      if (!res.ok) throw new Error('Failed to sign out other devices')
      return res.json()
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['sessions'] }) },
  })
}
