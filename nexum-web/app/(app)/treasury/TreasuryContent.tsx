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

export function TreasuryContent() {
  const { address }            = useAccount()
  const { data: batches = [] } = usePayrollBatches()
  const [range, setRange]      = useState('30')

  const now    = Math.floor(Date.now() / 1000)
  const fromTs = now - Number(range) * 86400

  // Payroll is USDC-denominated, so USD value == USDC amount (1:1).
  const inRange = batches.filter(b => (b.created_at ?? 0) >= fromTs)

  const completed   = inRange.filter(b => b.status === 'completed')
  const processing  = inRange.filter(b => b.status === 'processing' || b.status === 'partial')
  const totalPaid   = completed.reduce((s, b) => s + (b.total_amount ?? 0), 0)
  const recipients  = completed.reduce((s, b) => s + (b.recipient_count ?? 0), 0)

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

      {/* Recent payrolls (A2 will turn this into the tabbed table) */}
      <div className="rounded-xl border border-app-border bg-app-surface p-5">
        <div className="mb-4 flex items-center justify-between">
          <div>
            <p className="text-sm font-medium text-app-text">Recent payrolls</p>
            <p className="text-xs text-app-muted">Batch USDC payments with Memo references</p>
          </div>
          <Link href="/treasury/payroll">
            <Button size="sm" variant="outline">
              <Plus className="h-3.5 w-3.5" /> New batch
            </Button>
          </Link>
        </div>

        {inRange.length === 0 ? (
          <div className="flex flex-col items-center gap-2 py-8 text-center">
            <Building2 className="h-8 w-8 text-app-border" />
            <p className="text-sm text-app-muted">No payrolls in this period</p>
            <p className="text-xs text-app-muted">
              Send USDC to multiple wallets in one batch with unique Memo references
            </p>
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline" className="mt-2">Create first payroll</Button>
            </Link>
          </div>
        ) : (
          <div className="space-y-2">
            {inRange.slice(0, 10).map(batch => (
              <Link key={batch.id} href={`/treasury/payroll/${batch.id}`}>
                <div className="flex items-center justify-between rounded-xl border border-app-border bg-app-bg p-3 hover:border-app-accent/40 transition-colors cursor-pointer">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2">
                      <p className="text-sm font-medium text-app-text truncate">{batch.name}</p>
                      <Badge variant={
                        batch.status === 'completed'  ? 'success' :
                        batch.status === 'processing' ? 'arc'     :
                        batch.status === 'failed'     ? 'danger'  : 'warning'
                      }>
                        {batch.status}
                      </Badge>
                    </div>
                    <p className="text-xs text-app-muted">
                      {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
                      · {new Date(batch.created_at * 1000).toLocaleDateString()}
                    </p>
                  </div>
                  <ArrowRight className="h-4 w-4 shrink-0 text-app-muted" />
                </div>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
