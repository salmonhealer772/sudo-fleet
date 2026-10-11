---
name: status-card-query
description: Compile a prose interest prompt into a bounded CompanySearchQuery (query, key=value filters, capped limit) for a company/status-card search backend. Use when a natural-language request needs to become a structured search. PURE function. Load this skill before running status_card_query.py.
---

# status-card-query

Turn a natural-language interest prompt into a bounded, structured
`CompanySearchQuery` a status-card / company-search backend can execute.

```python
from status_card_query import compile_query, CompanySearchQuery

q = compile_query("Show me recent funding rounds for fintech startups in SF")
```

The tool is **PURE**: no network, no filesystem, no side effects, and
deterministic (same input → same output).

## What it does

- Strips filler phrases ("show me", "can you", "please", "find", ...).
- Extracts `top N` / `limit N` / `max N` into `limit` (clamped to 50).
- Extracts `key=value` filters (e.g. `sector=fintech`) into a dict.
- Collapses whitespace and truncates the query to 120 chars.

## Output shape

```python
CompanySearchQuery(
    query="recent funding rounds for fintech startups in SF",
    filters={},
    limit=10,
)
```

- `query` — cleaned interest text, ≤ 120 chars.
- `filters` — `key=value` pairs, keys lowercased.
- `limit` — default 10, capped at 50.

## When to use it

- A user or planner expresses an interest in natural language and a search
  backend needs a bounded, structured query.
- You need to pre-parse limits and filters out of prose before querying a
  company/status-card search API.
