import type { Request, Response, NextFunction } from 'express'
// __NEXUM_OBSERVABILITY_WIRED__ (phase7) capture unhandled route errors
import { captureException } from '../lib/logger'

export function errorHandler(err: Error, req: Request, res: Response, _next: NextFunction) {
  // Capture with request context (method + path, never the body - it may
  // hold PII/amounts). This logs structured JSON AND ships to Sentry when
  // SENTRY_DSN is set, so an unhandled route error is never lost.
  captureException(err, { scope: 'route', method: req.method, path: req.path })
  res.status(500).json({ error: 'Internal server error', message: err.message })
}
