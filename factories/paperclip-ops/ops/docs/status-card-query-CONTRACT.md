# status-card-query — tool contract

Compile a natural-language interest prompt into a bounded, structured search
query that a status-card / company-search backend can execute. This is the
PURE front half of a company/status-card lookup: it turns prose into a
`CompanySearchQuery` with no network, no I/O, and no side effects.

## Contract

- **Inputs:** `prose_interest` (str) — a natural-language prompt, e.g.
  `"Show me recent funding rounds for fintech startups in SF"`.
- **Output:** a frozen `CompanySearchQuery` dataclass:
  - `query` (str) — the cleaned interest text, truncated to **120 chars** max.
  - `filters` (dict) — `key=value` pairs pulled from the prompt (e.g.
    `sector=fintech`), keys lowercased; default `{}`.
  - `limit` (int) — how many results to return; default **10**, capped at **50**.
- **Behavior** (deterministic, best-effort):
  1. Empty or whitespace-only input → `CompanySearchQuery(query="", filters={}, limit=10)`.
  2. Strip filler phrases — case-insensitive (`i want to`, `i need to`,
     `can you`, `please`, `could you`, `would you`, `tell me about`,
     `look up`, `search for`, `find`, `show me`, `get me`, `give me`,
     `I'd like`, `I want`, `I need`, `can someone`).
  3. Extract a limit from `top N` / `limit N` / `max N`, clamp to ≤ 50, and
     remove the phrase from the query text.
  4. Extract `key=value` filters (keys lowercased), removing each match from
     the query text.
  5. Collapse runs of whitespace to single spaces and trim.
  6. Truncate the final query string to 120 characters.
- **Purity:** no network, no filesystem, no side effects. Same input always
  yields the same output.

## Worked example

```python
compile_query("Show me recent funding rounds for fintech startups in SF")
# -> CompanySearchQuery(query="recent funding rounds for fintech startups in SF",
#                       filters={}, limit=10)

compile_query("funding rounds sector=fintech region=SF top 25")
# -> CompanySearchQuery(query="funding rounds",
#                       filters={"sector": "fintech", "region": "SF"}, limit=25)
```

## Error / edge cases

- **Empty / whitespace input** → `query=""`, `filters={}`, `limit=10`.
- **`limit > 50`** (e.g. `limit 100`) → clamped to `50`.
- **No limit phrase** → `limit=10` (default).
- **No `key=value` pairs** → `filters={}`.
- **Very long prompt** → `query` truncated to 120 chars; limit/filters are
  extracted before truncation, so they still parse.

## Backend

Implemented as a pure function in `tools/status_card_query.py`
(`compile_query`). The status-card backend that executes the returned
`CompanySearchQuery` against a company search API is a separate consumer;
this contract covers the query-compilation surface only.
