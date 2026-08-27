// __NEXUM_IDEMPOTENCY_CLIENT__ (phase7 part2b)
//
// Helpers for sending a stable Idempotency-Key on money-moving POSTs, so a
// retried or double-tapped request dedupes at the API instead of moving money
// twice. Pairs with the server middleware added in Phase 7 Part 2.
//
// The rule that makes this correct: a key must be STABLE across retries of the
// SAME logical action, but FRESH for a new action. So we mint the key at the
// moment the user initiates (submit / mutate), keep it for as long as that one
// attempt is being retried, and only mint a new one for a genuinely new action.

export function newIdempotencyKey(): string {
  // Secure-context browsers all support crypto.randomUUID; fall back just in case.
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) {
    return crypto.randomUUID()
  }
  return `${Date.now()}-${Math.random().toString(16).slice(2)}-${Math.random().toString(16).slice(2)}`
}

// Build fetch headers with the idempotency key attached.
export function idempotentJsonHeaders(key: string): Record<string, string> {
  return { 'Content-Type': 'application/json', 'Idempotency-Key': key }
}
