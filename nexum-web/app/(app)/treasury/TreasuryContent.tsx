'use client'
import { useState } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import Link from 'next/link'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { usePayrollBatches } from '@/hooks/usePayroll'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Users, Building2, ArrowRight,
  Wallet, CheckCircle2, Clock,
} from 'lucide-react'

const RANGES = [
  ['7',   'Last 7 days'],
  ['30',  'Last 30 days'],
  ['90',  'Last 90 days'],
  ['365', 'Last year'],
] as const

type TabKey = 'all' | 'completed' | 'processing' | 'failed'

export function TreasuryContent() {
  const { address }            = useAccount()
  const { data: batches = [] } = usePayrollBatches()
  const [range, setRange]      = useState('30')
  const [activeTab, setTab]    = useState<TabKey>('all')

  const now    = Math.floor(Date.now() / 1000)
  const fromTs = now - Number(range) * 86400

  // Payroll is USDC-denominated, so USD value == USDC amount (1:1).
  const inRange = batches.filter(b => (b.created_at ?? 0) >= fromTs)

  const completed  = inRange.filter(b => b.status === 'completed')
  const processing = inRange.filter(b => b.status === 'processing' || b.status === 'partial')
  const failed     = inRange.filter(b => b.status === 'failed')
  const totalPaid  = completed.reduce((s, b) => s + (b.total_amount ?? 0), 0)
  const recipients = completed.reduce((s, b) => s + (b.recipient_count ?? 0), 0)

  const summary = [
    {
      label: 'Total paid (USD)',
      value: `$${formatAmount(totalPaid)}`,
      sub:   `across ${completed.length} completed batch${completed.length === 1 ? '' : 'es'}`,
      icon:  Wallet,
    },
    {
      label: 'Recipients paid',
      value: String(recipients),
      sub:   'in the selected period',
      icon:  CheckCircle2,
    },
    {
      label: 'In progress',
      value: String(processing.length),
      sub:   'processing or partial',
      icon:  Clock,
    },
  ]

  const tabData: Record<TabKey, typeof inRange> = {
    all:        inRange,
    completed:  completed,
    processing: processing,
    failed:     failed,
  }
  const rows = tabData[activeTab]

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Payroll</h1>
          <p className="text-sm text-app-muted">Batch payouts with USD equivalents · exportable</p>
        </div>
        <div className="flex gap-2">
          <select value={range} onChange={e => setRange(e.target.value)}
            className="rounded-lg border border-app-border bg-app-surface px-3 py-1.5 text-xs text-app-text outline-none">
            {RANGES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
          <Link href="/treasury/payroll">
            <Button size="sm">
              <Users className="h-4 w-4" /> New payroll
            </Button>
          </Link>
        </div>
      </div>

      {/* Summary cards */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3">
        {summary.map(({ label, value, sub, icon: Icon }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <div className="flex items-center justify-between">
              <p className="text-xs text-app-muted">{label}</p>
              <Icon className="h-4 w-4 text-app-muted" />
            </div>
            <p className="mt-1 font-mono text-xl font-semibold text-app-text">{value}</p>
            <p className="mt-0.5 text-xs text-app-muted">{sub}</p>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="mb-4 flex gap-1 rounded-lg border border-app-border bg-app-surface p-1 w-fit">
        {([
          ['all',        'All'],
          ['completed',  'Completed'],
          ['processing', 'Processing'],
          ['failed',     'Failed'],
        ] as const).map(([t, l]) => (
          <button key={t} onClick={() => setTab(t)}
            className={`rounded-md px-3 py-1.5 text-xs transition-colors
              ${activeTab === t ? 'bg-app-border text-app-text' : 'text-app-muted hover:text-app-text'}`}>
            {l} ({tabData[t].length})
          </button>
        ))}
      </div>

      {/* Batch table */}
      {rows.length === 0 ? (
        <div className="rounded-xl border border-app-border bg-app-surface p-8 text-center">
          <Building2 className="mx-auto mb-2 h-8 w-8 text-app-border" />
          <p className="text-sm text-app-muted">No {activeTab === 'all' ? 'payrolls' : `${activeTab} payrolls`} in this period</p>
          {activeTab === 'all' && (
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline" className="mt-3">
                <Plus className="h-3.5 w-3.5" /> Create first payroll
              </Button>
            </Link>
          )}
        </div>
      ) : (
        <div className="rounded-xl border border-app-border bg-app-surface overflow-hidden overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-app-border text-left text-xs text-app-muted">
                <th className="px-4 py-3 font-medium">Batch</th>
                <th className="px-4 py-3 font-medium">Recipients</th>
                <th className="px-4 py-3 font-medium">Total (USD)</th>
                <th className="px-4 py-3 font-medium">Chain</th>
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium"></th>
              </tr>
            </thead>
            <tbody>
              {rows.map(batch => (
                <tr key={batch.id} className="border-b border-app-border/50 last:border-0 hover:bg-app-bg/50 transition-colors">
                  <td className="px-4 py-3">
                    <Link href={`/treasury/payroll/${batch.id}`}
                      className="font-medium text-app-text hover:text-app-accent-text transition-colors">
                      {batch.name}
                    </Link>
                  </td>
                  <td className="px-4 py-3">
                    <span className="text-xs text-app-muted">{batch.recipient_count}</span>
                  </td>
                  <td className="px-4 py-3">
                    <span className="font-mono text-xs text-app-text">${formatAmount(batch.total_amount)}</span>
                  </td>
                  <td className="px-4 py-3">
                    <span className="text-xs text-app-muted capitalize">{batch.dest_chain ?? '-'}</span>
                  </td>
                  <td className="px-4 py-3 whitespace-nowrap text-xs text-app-muted">
                    {new Date(batch.created_at * 1000).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-3">
                    <Badge variant={
                      batch.status === 'completed'  ? 'success' :
                      batch.status === 'processing' ? 'arc'     :
                      batch.status === 'failed'     ? 'danger'  : 'warning'
                    }>
                      {batch.status}
                    </Badge>
                  </td>
                  <td className="px-4 py-3">
                    <Link href={`/treasury/payroll/${batch.id}`}
                      className="text-app-muted hover:text-app-accent-text transition-colors">
                      <ArrowRight className="h-4 w-4" />
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
