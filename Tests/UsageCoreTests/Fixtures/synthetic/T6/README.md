# T6 synthetic cliproxy payloads

Written from docs/plan.md ("cliproxy", "Reading passive signals", "Routing", "Fork's
quota poller"), not captured. No live payload existed yet (P0.2, P0.3), so the
wrappers and some field names are guesses:

- `credentials.json`: `GET /v8/management/credentials`. The `{"files": [...]}` wrapper
  is upstream's `auth-files` shape; the parser accepts a bare array too. `quota.signals`
  values appear both as strings and as string arrays (Go `http.Header`), with mixed
  header-name casing.
- `routing-strategy.json`: `GET /v0/management/routing/strategy` as `{"strategy": ...}`.
- `config-routing.json`: the `routing` object of `GET /v0/management/config`, as
  `scripts/capture-fixtures.sh` saves it. The `session-affinity` key name is a guess.
- `quota-history*.json`: the fork's `GET /v8/management/quota/history`. Window names
  `short` and `weekly`, `reading.windows` as an object or an array, camelCase fields.

The tests' expected values were worked out by hand from these files and plan.md.
