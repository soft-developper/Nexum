// __NEXUM_OBSERVABILITY__ (phase7) structured logging + thin Sentry capture
//
// Phase 7 Hardening. Two jobs, zero dependencies:
//
//   log.{debug,info,warn,error}(msg, fields?)  - structured JSON to stdout/stderr
//   captureException(err, context?)            - ship an error to Sentry IF a
//                                                SENTRY_DSN is configured; else
//                                                it just logs. Never throws.
//
// Why home-grown: the roadmap asks for "structured logging + Sentry" but the
// project deliberately keeps dependencies minimal and controlled. This gives
// JSON logs (greppable, ingestible by any log platform) and error capture via
// Sentry's plain HTTP ingest API - no SDK, no transitive deps, and it is inert
// unless SENTRY_DSN is set, so local/dev behaviour is unchanged.
//
// The point of this part is to stop losing failures. Silent `catch {}` and
// fire-and-forget `.catch(() => {})` swallow exactly the errors that cost us
// real debugging time (the fractional-bps crash hid this way). Route those
// through captureException instead and they surface.

type Level = 'debug' | 'info' | 'warn' | 'error'

const SERVICE     = 'nexum-api'
const ENV         = process.env.NODE_ENV ?? 'development'
const RELEASE     = process.env.APP_VERSION ?? process.env.npm_package_version ?? 'dev'
const SENTRY_DSN  = process.env.SENTRY_DSN ?? ''
const MIN_LEVEL   = (process.env.LOG_LEVEL as Level) ?? 'info'

const LEVEL_RANK: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 }

function emit(level: Level, message: string, fields?: Record<string, unknown>) {
  if (LEVEL_RANK[level] < LEVEL_RANK[MIN_LEVEL]) return
  const line = {
    ts:      new Date().toISOString(),
    level,
    service: SERVICE,
    env:     ENV,
    msg:     message,
    ...(fields ?? {}),
  }
  // JSON on one line: parseable by any log platform, still readable in a tail.
  const out = JSON.stringify(line)
  if (level === 'error' || level === 'warn') console.error(out)
  else console.log(out)
}

export const log = {
  debug: (m: string, f?: Record<string, unknown>) => emit('debug', m, f),
  info:  (m: string, f?: Record<string, unknown>) => emit('info', m, f),
  warn:  (m: string, f?: Record<string, unknown>) => emit('warn', m, f),
  error: (m: string, f?: Record<string, unknown>) => emit('error', m, f),
}

// ── Sentry DSN parsing ──────────────────────────────────────
// A DSN looks like: https://<publicKey>@<host>/<projectId>
// The ingest endpoint is:  https://<host>/api/<projectId>/store/
// with an X-Sentry-Auth header carrying the public key. We build this by hand
// so we need no SDK.
interface ParsedDsn { endpoint: string; publicKey: string }
function parseDsn(dsn: string): ParsedDsn | null {
  try {
    const u = new URL(dsn)
    const projectId = u.pathname.replace(/^\//, '')
    if (!u.username || !projectId) return null
    return {
      endpoint:  `${u.protocol}//${u.host}/api/${projectId}/store/`,
      publicKey: u.username,
    }
  } catch { return null }
}
const DSN = SENTRY_DSN ? parseDsn(SENTRY_DSN) : null

/*
  Capture an error. Always logs it (so nothing is lost even without Sentry), and
  additionally ships it to Sentry when configured. Fire-and-forget by design -
  it never throws and never blocks the caller, because capturing an error must
  not itself break a request or a job.
*/
export function captureException(
  err: unknown,
  context?: Record<string, unknown>,
): void {
  const e = err instanceof Error ? err : new Error(String(err))

  // Always log - this is the part that guarantees the failure is visible.
  log.error(e.message, {
    err:   e.name,
    stack: e.stack,
    ...(context ?? {}),
  })

  if (!DSN) return

  const event = {
    event_id:  crypto.randomUUID().replace(/-/g, ''),
    timestamp: new Date().toISOString(),
    platform:  'node',
    level:     'error',
    release:   RELEASE,
    environment: ENV,
    server_name: SERVICE,
    exception: {
      values: [{
        type:  e.name,
        value: e.message,
        stacktrace: e.stack ? { frames: parseStack(e.stack) } : undefined,
      }],
    },
    extra: context ?? {},
  }

  const auth =
    `Sentry sentry_version=7, sentry_client=nexum-thin/1.0, ` +
    `sentry_key=${DSN.publicKey}`

  // Node 18+ has global fetch. Do not await - capture must not block.
  fetch(DSN.endpoint, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json', 'X-Sentry-Auth': auth },
    body:    JSON.stringify(event),
  }).catch(() => {
    // If Sentry itself is unreachable we already logged the error above; there
    // is nothing more useful to do than swallow the reporting failure.
  })
}

// Turn a V8 stack string into Sentry frames (best-effort; Sentry is tolerant of
// a partial stacktrace, and we already carry the raw stack in the log).
function parseStack(stack: string): Array<Record<string, unknown>> {
  const frames: Array<Record<string, unknown>> = []
  for (const line of stack.split('\n').slice(1)) {
    const m = /at (.+?) \(?(.+?):(\d+):(\d+)\)?$/.exec(line.trim())
    if (m) {
      frames.push({
        function: m[1],
        filename: m[2],
        lineno:   Number(m[3]),
        colno:    Number(m[4]),
      })
    }
  }
  // Sentry expects innermost frame last.
  return frames.reverse()
}

/*
  Install process-level handlers so a rejected promise or a thrown error that
  escapes all handlers is captured instead of silently killing (or silently
  being ignored by) the process. Call once at startup.
*/
export function installGlobalErrorCapture(): void {
  process.on('unhandledRejection', (reason: unknown) => {
    captureException(reason, { kind: 'unhandledRejection' })
  })
  process.on('uncaughtException', (err: Error) => {
    captureException(err, { kind: 'uncaughtException' })
    // An uncaught exception leaves the process in an undefined state. We have
    // reported it; let the platform restart us rather than limp on.
    // (Give the async capture a beat to flush before exiting.)
    setTimeout(() => process.exit(1), 250)
  })
  log.info('global error capture installed', {
    sentry: DSN ? 'enabled' : 'disabled',
  })
}
