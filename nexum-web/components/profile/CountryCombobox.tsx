"use client"
// __NEXUM_COUNTRY_COMBOBOX__
// Searchable nationality picker. Mirrors CurrencyCombobox's interaction
// pattern (button + dropdown + search + click-outside) but reads the ISO 3166
// country list. Stores/returns the alpha-2 code; shows name + derived flag.
import { useState, useRef, useEffect, useMemo } from 'react'
import { COUNTRIES, countryName, countryFlag } from '@/lib/countries'
import { ChevronDown, Search, X } from 'lucide-react'

export function CountryCombobox({
  value,
  onChange,
  placeholder = 'Search country…',
}: {
  value: string | null | undefined
  onChange: (code: string) => void
  placeholder?: string
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const boxRef = useRef<HTMLDivElement>(null)

  const results = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return COUNTRIES
    return COUNTRIES.filter(
      (c) => c.name.toLowerCase().includes(q) || c.code.toLowerCase() === q,
    )
  }, [query])

  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const hasValue = !!value

  return (
    <div ref={boxRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center justify-between gap-2 rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none hover:border-app-accent/50"
      >
        <span className="flex items-center gap-2 truncate">
          <span className="text-base">{hasValue ? countryFlag(value) : '\u{1F30D}'}</span>
          <span className={hasValue ? 'font-medium' : 'text-app-muted'}>
            {hasValue ? countryName(value) : 'Select country'}
          </span>
        </span>
        <span className="flex items-center gap-1 shrink-0">
          {hasValue && (
            <X
              className="h-3.5 w-3.5 text-app-muted hover:text-app-text"
              onClick={(e) => { e.stopPropagation(); onChange('') }}
            />
          )}
          <ChevronDown className="h-4 w-4 text-app-muted" />
        </span>
      </button>

      {open && (
        <div className="absolute z-50 mt-1 w-full rounded-lg border border-app-border bg-app-surface shadow-lg">
          <div className="flex items-center gap-2 border-b border-app-border px-3 py-2">
            <Search className="h-3.5 w-3.5 text-app-muted" />
            <input
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={placeholder}
              className="w-full bg-transparent text-sm text-app-text outline-none placeholder:text-app-muted"
            />
          </div>
          <ul className="max-h-64 overflow-y-auto py-1">
            {results.length === 0 && (
              <li className="px-3 py-3 text-center text-xs text-app-muted">
                No country matches "{query}".
              </li>
            )}
            {results.map((c) => (
              <li key={c.code}>
                <button
                  type="button"
                  onClick={() => { onChange(c.code); setOpen(false); setQuery('') }}
                  className={`flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-app-bg ${
                    c.code === value ? 'bg-app-bg' : ''
                  }`}
                >
                  <span className="text-base">{countryFlag(c.code)}</span>
                  <span className="truncate font-medium text-app-text">{c.name}</span>
                  <span className="ml-auto text-xs text-app-muted">{c.code}</span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
