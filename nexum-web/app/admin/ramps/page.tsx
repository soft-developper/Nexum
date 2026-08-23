'use client'
import { useEffect, useState } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch } from '@/hooks/useAdminAuth'
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from 'recharts'
import { Loader2, Users, ArrowDownToLine, ArrowUpFromLine, AlertTriangle } from 'lucide-react'
import { useTokens } from '@/lib/tokens'

const money = (n: number) => `$${(n ?? 0).toLocaleString(undefined, { maximumFractionDigits: 2 })}`

function kycBadge(status: string) {
  const map: Record<string, string> = {
    approved:    'bg-emerald-500/15 text-emerald-400',
    rejected:    'bg-red-500/15 text-red-400',
    not_started: 'bg-app-border/40 text-app-muted',
  }
  const cls = map[status] ?? 'bg-app-accent/15 text-app-accent-text'
  const label = status.replace(/_/g, ' ')
  return <span className={`inline-block rounded-full px-2 py-0.5 text-[11px] font-medium capitalize ${cls}`}>{label}</span>
}

export default function AdminRamps() {
  const t = useTokens()
  const [data, setData]       = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    adminFetch('/admin/manage/ramps')
      .then(r => r.json()).then(setData)
      .catch(() => {}).finally(() => setLoading(false))
  }, [])

  const corridorChart = (data?.corridors ?? []).map((c: any) => ({
    label: `${c.currency} ${c.direction === 'onramp' ? 'in' : 'out'}`,
    volume: Math.round(c.volume),
    direction: c.direction,
  }))

  return (
    <AdminShell>
      <h1 className="mb-6 text-xl font-semibold text-app-text">On / Off-ramp analytics</h1>

      {loading ? (
        <div className="flex h-40 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-app-accent-text" /></div>
      ) : !data ? (
        <p className="text-sm text-app-muted">No ramp data available yet.</p>
      ) : (
        <div className="space-y-4">
          {/* Summary cards */}
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <StatCard icon={<Users className="h-4 w-4" />} label="KYC'd users"
              value={String(data.funnel.approved)} sub={`${data.funnel.total} total - ${data.funnel.pending} pending`} tone="text-app-text" />
            <StatCard icon={<ArrowDownToLine className="h-4 w-4" />} label="On-ramp volume"
              value={money(data.volume.onramp.usd)} sub={`${data.volume.onramp.count} deposits - ${money(data.volume.onramp.week)} this week`} tone="text-emerald-400" />
            <StatCard icon={<ArrowUpFromLine className="h-4 w-4" />} label="Off-ramp volume"
              value={money(data.volume.offramp.usd)} sub={`${data.volume.offramp.count} payouts - ${money(data.volume.offramp.week)} this week`} tone="text-app-accent-text" />
            <StatCard icon={<AlertTriangle className="h-4 w-4" />} label="Health"
              value={String(data.health.failedOrReturnedDrains + data.health.rejectedKyc)}
              sub={`${data.health.pendingDeposits} pending - ${data.health.failedOrReturnedDrains} failed - ${data.health.rejectedKyc} rejected KYC`}
              tone={data.health.failedOrReturnedDrains > 0 ? 'text-red-400' : 'text-app-text'} />
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            {/* Corridor breakdown */}
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-4 text-sm font-medium text-app-text">Volume by corridor (USD)</p>
              {corridorChart.length === 0 ? (
                <p className="py-10 text-center text-sm text-app-muted">No settled volume yet.</p>
              ) : (
                <ResponsiveContainer width="100%" height={Math.max(180, corridorChart.length * 38)}>
                  <BarChart data={corridorChart} layout="vertical" barSize={16}>
                    <XAxis type="number" tick={{ fill: t.muted, fontSize: 10 }} axisLine={false} tickLine={false} tickFormatter={(v: number) => `$${v}`} />
                    <YAxis type="category" dataKey="label" tick={{ fill: t.text, fontSize: 10 }} axisLine={false} tickLine={false} width={70} />
                    <Tooltip
                      contentStyle={{ background: t.surface, border: `1px solid ${t.border}`, borderRadius: 8, fontSize: 12 }}
                      itemStyle={{ color: t.text }}
                      formatter={(v: number) => [money(v), 'Volume']}
                    />
                    <Bar dataKey="volume" radius={[0,4,4,0]}>
                      {corridorChart.map((c: any, i: number) => <Cell key={i} fill={c.direction === 'onramp' ? '#10B981' : t.accent} />)}
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
              )}
            </div>

            {/* Funnel + type + providers */}
            <div className="rounded-xl border border-app-border bg-app-surface p-5">
              <p className="mb-4 text-sm font-medium text-app-text">KYC funnel & mix</p>
              <div className="space-y-3 text-sm">
                <Row label="Approved"    value={data.funnel.approved}    tone="text-emerald-400" />
                <Row label="Pending"     value={data.funnel.pending}     tone="text-app-accent-text" />
                <Row label="Rejected"    value={data.funnel.rejected}    tone="text-red-400" />
                <Row label="Not started" value={data.funnel.notStarted}  tone="text-app-muted" />
                <div className="my-2 border-t border-app-border" />
                <Row label="Individuals" value={data.byType.individual} tone="text-app-text" />
                <Row label="Businesses"  value={data.byType.business}   tone="text-app-text" />
                <div className="my-2 border-t border-app-border" />
                {data.providers.map((p: any) => (
                  <Row key={p.provider} label={`Provider: ${p.provider}`} value={p.customers} tone="text-app-text" />
                ))}
              </div>
            </div>
          </div>

          {/* KYC'd users table */}
          <div className="rounded-xl border border-app-border bg-app-surface p-5">
            <p className="mb-4 text-sm font-medium text-app-text">Registered ramp users</p>
            {data.customers.length === 0 ? (
              <p className="py-6 text-center text-sm text-app-muted">No registered ramp users yet.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr className="border-b border-app-border text-xs text-app-muted">
                      <th className="pb-2 pr-4 font-medium">User</th>
                      <th className="pb-2 pr-4 font-medium">Type</th>
                      <th className="pb-2 pr-4 font-medium">KYC</th>
                      <th className="pb-2 pr-4 font-medium">ToS</th>
                      <th className="pb-2 pr-4 font-medium">Provider</th>
                      <th className="pb-2 font-medium">Registered</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.customers.map((c: any, i: number) => (
                      <tr key={i} className="border-b border-app-border/50 last:border-0">
                        <td className="py-2.5 pr-4 text-app-text">
                          <div className="font-medium">{c.username ?? 'unknown'}</div>
                          <div className="text-[11px] text-app-muted">{c.email ?? c.accountId}</div>
                        </td>
                        <td className="py-2.5 pr-4 capitalize text-app-muted">{c.type}</td>
                        <td className="py-2.5 pr-4">{kycBadge(c.kycStatus)}</td>
                        <td className="py-2.5 pr-4 capitalize text-app-muted">{c.tosStatus}</td>
                        <td className="py-2.5 pr-4 text-app-muted">{c.provider}</td>
                        <td className="py-2.5 text-app-muted">{c.createdAt ? new Date(c.createdAt * 1000).toLocaleDateString() : '-'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      )}
    </AdminShell>
  )
}

function StatCard({ icon, label, value, sub, tone }: { icon: React.ReactNode; label: string; value: string; sub: string; tone: string }) {
  return (
    <div className="rounded-xl border border-app-border bg-app-surface p-5">
      <div className="mb-1 flex items-center gap-1.5 text-xs text-app-muted">{icon}{label}</div>
      <div className={`text-2xl font-semibold ${tone}`}>{value}</div>
      <div className="mt-1 text-[11px] text-app-muted">{sub}</div>
    </div>
  )
}

function Row({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-app-muted">{label}</span>
      <span className={`font-medium ${tone}`}>{value}</span>
    </div>
  )
}
