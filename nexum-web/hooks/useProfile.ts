'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { apiFetch } from '@/hooks/useAuth'
import type { UserProfile } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

// Fetch current user's OWN profile via the authenticated owner endpoint.
// /profile/me returns the owner-only fields (DOB, nationality, gender,
// location, age) that the public routes strip. Still gated on having a
// wallet address so it only fires once the account is fully provisioned.
export function useProfile() {
  const { address } = useAccount()
  return useQuery<UserProfile | null>({
    queryKey:  ['profile', 'me', address],
    queryFn:   async () => {
      const res = await apiFetch('/profile/me')
      if (res.status === 404) return null
      if (!res.ok) throw new Error('Failed to fetch profile')
      return res.json()
    },
    enabled:       !!address,
    staleTime:     60_000,
    retry:         false,
  })
}

// Fetch any profile by username
export function useProfileByUsername(username: string | null) {
  return useQuery<UserProfile | null>({
    queryKey: ['profile-username', username],
    queryFn:  async () => {
      if (!username) return null
      const res = await fetch(`${API}/profile/${username}`)
      if (res.status === 404) return null
      if (!res.ok) throw new Error('Failed to fetch profile')
      return res.json()
    },
    enabled:   !!username,
    staleTime: 30_000,
  })
}

// Fetch profile by wallet address (for displaying other users)
export function useProfileByAddress(address: string | null | undefined) {
  return useQuery<UserProfile | null>({
    queryKey: ['profile-address', address?.toLowerCase()],
    queryFn:  async () => {
      if (!address) return null
      const res = await fetch(`${API}/profile/wallet/${address}`)
      if (res.status === 404) return null
      if (!res.ok) return null
      return res.json()
    },
    enabled:   !!address,
    staleTime: 60_000,
    retry:     false,
  })
}

// Check username availability
export async function checkUsername(username: string): Promise<{ available: boolean; error?: string }> {
  const res = await fetch(`${API}/profile/check/${username}`)
  return res.json()
}
