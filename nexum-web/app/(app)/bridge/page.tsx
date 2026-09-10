import { BridgeCard } from '@/components/bridge/BridgeCard'
import { BridgeHistory } from '@/components/bridge/BridgeHistory'
import { ClientOnly } from '@/components/ui/client-only'
import { SectionGuard } from '@/components/layout/SectionGuard'

export const metadata = { title: 'Bridge, Nexum' }

function BridgeSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 h-5 w-32 animate-pulse rounded bg-app-border" />
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-app-border" />
      </div>
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="mb-4 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="h-11 animate-pulse rounded-lg bg-app-border" />
    </div>
  )
}

// 'bridge' is now a maintenance section, so gate the page like /ramp: when the
// section (or the whole platform) is down, users see the maintenance state
// instead of the bridge UI. Admins are not gated (they verify via the panel).
export default function BridgePage() {
  return (
    <SectionGuard section="bridge">
      <div>
        <div className="mb-6">
          <h1 className="text-xl font-semibold text-app-text">Bridge</h1>
        </div>
        <ClientOnly fallback={<BridgeSkeleton />}>
          <BridgeCard />
          {/* A bridge that outlives the page must never become invisible. */}
          <BridgeHistory />
        </ClientOnly>
      </div>
    </SectionGuard>
  )
}
// __NEXUM_DASH_CLEANUP_A__ 20260910-130315
