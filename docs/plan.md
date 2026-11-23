# usage-monitor plan

Status: draft for discussion, 2026-11-22. Nothing is built yet.

## Goal

A macOS menubar app that shows how much subscription quota is left for each
provider across every account we pool. It is informative only: no alerts or
notifications.

- One number per provider and window, for example "Claude weekly: 59% left across
  3 subscriptions".
- A gauge for the 5-hour window that shows each account's level, when the next one
  refills, and when the pool is likely to hit its limit at the current burn rate.
- Sources: cliproxy (Claude and Codex OAuth accounts) and ocgo-proxy (OpenCode Go
  workspaces). No subscription logins on the Mac; the app talks only to the two
  proxies.

The reference app, [ai-usage-limit-monitor](https://github.com/vishnu09bharath/ai-usage-limit-monitor),
reads one account per provider from the local machine. Our case is different: the
accounts live on the cliproxy VM, several per provider, behind proxies that already
know their state.

## Data sources

### cliproxy (CLIProxyAPI, Claude and Codex)

We run a custom fork (fixed custom-quota image, see agent-hub
`docs/deployment-2026-11-09.md`). Its source is on thearch at
`/home/steve/cpa-idle-fix/src`: detached at `3b2af65` ("v3 baseline", 23 files on top
of upstream `v8.0.67`) plus uncommitted Codex WebSocket edits, and
`/home/steve/cpa-idle-fix/manifest.json` ties it to the deployed image. The original
custom source is also on the VM at `/home/steve/cliproxy/custom-backend-build`. The
notes below are from upstream `6eb8554` (2026-11-23) except where marked "fork".

| What | Route | Notes |
|---|---|---|
| Credential list | `GET /v8/management/credentials` (or `/v0/management/auth-files`) | Per account: `auth_index`, `provider`, `email`, `disabled`, `unavailable`, `status`, `success`/`failed`, `recent_requests` (20 buckets of 10 min), and `quota.signals` + `quota.observed_at`. As captured (P0.3): the list is `{"files": [...], "observed_at"}`; `priority` and `weight` appear only when set; a quota-blocked credential has `unavailable: true`, `quota_blocked: true`, `status: "error"`, `next_retry_after` and a `cooldowns[]` entry with `scope: "credential"` and the same `retry_at` (model-scope entries sit beside it); `model_quotas.<model>` keeps older per-model copies of the signals, and `quota` is the newest of them. Other providers (`antigravity`) are listed too and skipped. |
| Passive quota | inside the list, `quota.signals` | Copied from response headers on real traffic: Claude `Anthropic-Ratelimit-Unified-5h-Utilization`, `-7d-Utilization`, `-5h-Reset`, `-7d-Reset`, `-Status`; Codex `X-Codex-Primary-Used-Percent`, `-Window-Minutes`, `-Reset-At`, `-Reset-After-Seconds`, `X-Codex-Secondary-*`, plan type. Free to read and current while an account carries traffic. See "Reading passive signals" below. |
| Active quota | `POST /v8/management/requests/api-call` | Calls a provider URL with the stored token (`$TOKEN$` placeholder). Claude: `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` returns `five_hour`, `seven_day` (each `utilization` 0-100, `resets_at` RFC 3339). Model-scoped weekly limits (`seven_day_opus`, `seven_day_sonnet`, or `limits[]` with `kind: "weekly_scoped"`) aren't on our plans and are ignored. Codex: `GET https://chatgpt.com/backend-api/wham/usage` with `Chatgpt-Account-Id` returns `rate_limit.primary_window` / `secondary_window` (`used_percent`, `limit_window_seconds`, `reset_at`), `plan_type`. It does not refresh the token, so expect occasional 401s. |
| Fork's quota poller | fork: `GET /v8/management/quota/history`, `POST /v8/management/quota/refresh` (not under `/v0`) | Fork's `internal/quota` starts on boot and polls Claude and Codex `usage` every 300 s by default. Its `pools[]` don't follow our pool rules: one entry per credential file with no dedupe, `remaining` null as soon as one account is stale, `knownRemaining` a sum rather than a mean, no weekly-blocked exclusion, and provider `"anthropic"` where the credential list says `"claude"`. Read only per-account data and compute everything else in the app: the latest reading from `accounts[].reading.windows` (values are remaining %, not used %), and past readings from `pools[].history[].accounts[]` (`id`, `status`, `remaining`, `observedAt`, `resetAt`) with an explicit `?range=` (1h to 720h, default 24h). Each observation is written into both the `short` and the `weekly` pool, and knots carry earlier readings forward, so dedupe by `(id, provider, pool window, observedAt)` and keep only `status: "ok"` entries with a `remaining`. The route answers 200 even when the poller is off; a provider whose accounts show `status: "paused"` has no fork history. Join to the credential list by `account.id`, mapping `"anthropic"` to `"claude"`. As captured (P0.3, served live with 200): each `accounts[]` entry nests `id`, `provider`, `enabled` under `account`, beside `status`, `lastAttempt`, `lastSuccess`, `nextAttempt` and `reading`; the reading's time is `reading.at`, and `reading.windows` is an array of `{id: "short" or "weekly", durationSeconds: 18000 or 604800, remaining, resetAt, resetKind}`. Timestamps have up to 9 fractional digits, and Go's zero time stands for unset. API-key credentials appear as `claude:apikey:<12 hex>` with status `"unsupported"` or `"removed"` and no reading; they aren't in the credential list and don't count when deciding whether a provider is paused (a provider with only such accounts gets no fork state). History entries also show `"unsupported"`, `"added"` and `"stale_or_unsupported"`; a carried-forward entry turns `"stale_or_unsupported"` once its `resetAt` passes, and the dedupe keeps its earlier `"ok"` copy when there is one; an observation first written after its `resetAt` has none and is dropped. Top-level `events[]` (credentials added and removed) is ignored. |

Reading passive signals:

- Header names are stored canonicalized (`http.CanonicalHeaderKey`). Match them
  case-insensitively. Every value in the P0.3 capture is a single JSON string
  (`"0.31"`, `"1795417200"`), not a string array.
- Claude utilization is a fraction (0.53, and it can exceed 1.0). Multiply by 100 and
  clamp to 0-100. Claude resets are Unix epoch seconds.
- Codex window length comes from `-Window-Minutes` (300 = 5 hours, 10080 = weekly).
  The primary window is often the weekly one, with no secondary. When `-Reset-At` is
  missing, use `quota.observed_at` + `-Reset-After-Seconds`.
- Each response that carries any quota header replaces the whole `quota.signals` map,
  and some Anthropic responses omit the 5-hour headers. The app therefore keeps the
  last reading per account and window with its own timestamp, and a newer snapshot
  that lacks a window doesn't erase it.
- A missing reset time, epoch 0 or Go's zero time (`0001-01-01T00:00:00Z`, which the
  fork's poller emits when upstream omits `resets_at`) means "unset", never "past".

Auth: management key as `Authorization: Bearer` or `X-Management-Key`.
Non-local callers need `allow-remote: true`, which the app requires since it runs on
the Mac. Five bad attempts ban the IP for 30 min, so setup must stop at the first 401,
and so must the background poller (see Architecture). The key is stored in the macOS
Keychain.

`allow-remote` is one boolean that admits every non-loopback caller; there is no
address allowlist. `https://cliproxy.eu1.netbird.services` is a public endpoint that
forwards to `:8317` (agent-hub `docs/deployment-2026-11-09.md`). Turning
`allow-remote` on without blocking `/v0/management/*` and `/v8/management/*` at that
ingress exposes the management API, including credential download (raw OAuth tokens),
to the internet. Block those paths at the public ingress first; the app uses the
NetBird address.

Identity for deduplication, using listing fields only (never download auth files;
they hold tokens):

- Claude: the 8-hex hash in the credential name `claude-<hash>-<email>.json`. It is
  the SHA-256 of `organization_uuid`, or of `account_uuid` when there is no
  organization, so two organizations under one email stay separate. Legacy names
  `claude-<email>.json` fall back to the email. Until cliproxy migrates it, a legacy
  file and a hashed file for the same subscription (or an account-hashed file and its
  organization-hashed successor) get different keys and would count twice. Phase 0
  checks for such pairs; confirmed ones go into an alias list in the app's settings.
- Codex: `chatgpt_account_id` (in `id_token`).
- OpenCode Go: the account name. Each one is assumed to be a separate workspace;
  Phase 0 checks it.

Superseded on 2026-11-23 (see "P0.4 as captured" and Decisions): the capture shows
team seats sharing a Claude hash or a Codex `chatgpt_account_id` with separate
quotas, so identity becomes the seat: the Claude hash plus the email, and the Codex
`chatgpt_account_id` plus the email. The code still uses the rule above until T4b.

Routing: `routing.strategy` is `round-robin` (default), `weighted-round-robin` or
`fill-first`. Read it from `GET /v0/management/routing/strategy`, which returns the
default when the config omits it. The v8 config path returns 404 in that case.
Session affinity is not in that response; read it from `GET /v0/management/config`
(`routing`). Priority tiers (each credential's `priority` in the listing; higher
wins, default 0) apply under every strategy. `weight` (default 1) applies to
`weighted-round-robin`, where `weight <= 0` takes a credential out of rotation, so
it counts as unavailable. All of them change which account takes traffic, so the
forecast needs them.

A quota-blocked credential (`unavailable: true`) counts as cooling down until the
latest of its `next_retry_after` and credential-scope `cooldowns[].retry_at` while
that time is still ahead, so Pool rule 5 can place its refill. With no retry time
ahead it stays unavailable with no known end. When every enabled credential of an
account is blocked, the account comes back with the credential whose end is
earliest; only when none has a known end does it carry all their reasons.

### ocgo-proxy (OpenCode Go)

`GET /_ocgo/status` with any client token (`Authorization: Bearer`). Already returns
everything per account, with no keys:

```json
{ "time": "...", "accounts": [ {
    "name": "team-a", "available": true, "headroom": 38, "exhausted": false,
    "polled_at": "...", "poll_error": "",
    "windows": { "rolling": {"status": "ok", "percent": 62, "resets_at": "..."},
                 "weekly":  {...}, "monthly": {...} },
    "console_available": true, "free_available": true } ] }
```

The proxy itself polls Go's `/v1/usage` every `usage_poll_interval` (2 min in the
example config). Routing is "most headroom first", so accounts drain evenly, unless
`forced_account` is set, which pins all traffic to one account.

Reading the status:

- No `polled_at` means the account was never polled: unknown. `headroom` is 100 and
  `percent` is 0 until then, which would otherwise read as full.
- After a failed poll, ocgo keeps the last good windows and their `polled_at`, and
  sets `poll_error`. Show that reading with its age.
- Read a window's `percent` (used %) only when its `status` is `"ok"` or
  `"rate-limited"`. The P0.3 capture shows `"rate-limited"` on a window at its limit
  (team-a monthly: `percent` 100, `resets_at` equal to the account's
  `exhausted_until`); that is a reading, and skipping it would make the window
  unknown. Other statuses are still ignored.
- A window past its `resets_at` keeps its old percent. Treat it as Pool rule 3 says.
- "Usable now" follows `available`; `exhausted`, `exhausted_until` and
  `cooldown_until` say why and until when. While `forced_account` is set, only that
  account is usable, because ocgo doesn't fail over to the others. A forced account
  also skips ocgo's availability check, so in that mode its cooldown is advisory and
  only its windows decide whether it is usable.

### Window mapping

| Provider | 5-hour | Weekly | Other |
|---|---|---|---|
| Claude | `five_hour` / `unified-5h` | `seven_day` / `unified-7d` | none |
| Codex | window of 5 hours | window of 7 days | code review limit, credits |
| OpenCode Go | `rolling` | `weekly` | `monthly` |

Classify Codex windows by length, not by position: `-Window-Minutes` in passive
signals, `limit_window_seconds` from `wham/usage`. A reading with no length stays out
of both pools (the primary window is often the weekly one) and shows as unclassified
in the hover detail.

## Pool rules

These follow agent-hub's pooled-quota investigation. The user confirmed that every
subscription within a provider has the same plan.

1. **Pool remaining** per provider and window = mean of `100 - used%` over unique,
   enabled accounts. Same capacity per account, so the mean is the pool share.
2. **Deduplicate** accounts by identity (see Data sources), not by credential file.
3. **Unknown stays unknown.** An account is unknown when it has never been read or
   its only readings failed. It is never counted as 0% or 100%. With unknown
   accounts the pooled number becomes a range, with each unknown at 0% and then at
   100% ("41-74%"), and the row says "2 of 3 known". The overlap line draws only
   known accounts. An old reading is not unknown: while cliproxy carries all of an
   account's traffic, an idle account's quota changes only by resetting, so its last
   reading stands, shown with its age. A window past its `resets_at` counts as reset
   (100% left) only with proof that nothing used the account since the reset:
   - cliproxy: the account's `success` + `failed` counters are unchanged since a
     listing the app took before the reset. A drop in the counters (cliproxy
     restarted) or no pre-reset listing gives no proof. `recent_requests` isn't
     used: its 10-minute buckets carry VM-local times without a date and cover only
     200 minutes.
   - ocgo: a successful poll at or after the reset (`polled_at >= resets_at`), which
     replaces the window anyway.
   - Either: a fresh reading of that window taken after the reset.

   Otherwise the current value is unknown, and the old value stays in the hover
   detail.
4. **Quota vs usable.** An account blocked by a longer window (Claude or Codex
   weekly, Go weekly or monthly) or otherwise unavailable (cliproxy `unavailable`,
   ocgo `available: false`, cooling down, or not the `forced_account`) still shows its
   5-hour quota. In the
   5-hour gauge, grey it out and count it as 0 in "usable now". The menubar % and
   the number beside the 5-hour line are the usable share; when it differs from the
   raw quota, the dropdown shows both ("usable 30%, quota 55%").
5. **Next refill vs full recovery.** Accounts reset at different times. Report the
   next refill ("14:10, +27% of pool") and do not invent one pool reset time. The
   next refill is the first moment usable quota rises: evaluate it at each known
   5-hour reset, longer-window reset, block end and cooldown expiry. A blocked
   account's 5-hour reset alone isn't a refill; its block ending is.
6. **Freshness on every number.** Show the age of each reading. Mark readings older
   than a threshold.

## Gauge design

### Decision: the overlap line (E)

Mockup: [docs/mockups/gauges-overlap.html](mockups/gauges-overlap.html), option E.

- The line is the 0-100% scale. Each subscription is a bar from 0 to its remaining
  %, all the same thickness, drawn on top of each other with the emptiest on top.
  Reading left to right: the emptiest subscription's color up to its level, then the
  next one's, then the fullest one's up to its level. Empty track after that.
- Square ends; any rounding at most 1 px.
- Dropdown (opened from the menubar item): one row per provider, one color per
  subscription, the pooled % as the number beside the line, and under it, bottom
  right, the time left before the next reset ("reset in 1h 35m", the next refill as
  Pool rule 5 defines it, which also covers the case where every non-full
  subscription is blocked; "reset in 5h" when every enabled subscription has full, usable 5-hour quota, since a new
  window starts with the next request). Hover gives each subscription's %, refill
  time and freshness.
- Menubar: no line. Each provider's monochrome logo and its pooled 5-hour usable %
  (Pool rules 3 and 4), as tight as
  stays legible: 14 px glyph, 3 px to the number, 10 px between providers
  ("48%" after each logo). Logos are white on transparent, in `assets/logos/`
  (from T3 Code's MIT-licensed icons). The % sign stays.
- Menubar setting, "Menubar icon": Normal or Compact.
  - Normal: logos and % as above, always shown.
  - Compact: one 16 px icon, the three-spoke node glyph `assets/icons/compact.svg`
    (generated by `scripts/glyphs.py`; ring and 4-arm versions were rejected). Clicking it expands the
    item into the normal logos and % for 3 s, then it collapses. A second click while
    expanded opens the dropdown. Mockup: `docs/mockups/gauges-overlap.html`.
- Known tradeoffs: the line reaches the fullest subscription while the number is
  the pooled average; colors swap places when two subscriptions cross.

### Rejected along the way

All mockups are in `docs/mockups/`:

- `gauges.html`: pool bar, ribbons and the stacked "runway" forecast chart. The
  runway stays a candidate for a detail or forecast view, not for the gauge.
- `gauges-nested.html`: nested lines of decreasing thickness, and a ring version.
- `gauges-options.html`: cells, segmented pool, pool line with ticks, range, lanes,
  and pool line with next refill.
- `gauges-mix.html`: additive light mix (unreadable), split line and taper (ugly).
- `gauges-fable.html` (by Claude Fable 5.2): inlay, segments with refill echo, fade
  and refill rail. The refill echo led to E once its pale part was dropped.

What the simulation shows:

- With round-robin (cliproxy default) or most-headroom (ocgo-proxy), accounts drain
  **together**. The "one empties and reveals the next" behavior only happens with
  `fill-first`.
- Claude's 5-hour window starts at the first request after a reset. Routing
  therefore changes when windows reset, and the lockout times move with it. In
  the toy scenario at 90%/h, round-robin had 11 minutes of lockout, most-headroom
  30 and fill-first 72. That is one scenario, not a rule. The forecast should
  simulate the routing mode that is actually configured.

Weekly gauge: a single meter per provider plus a **pace marker** showing where usage
would be if spread evenly through the week, so "59% left" also says whether we are
ahead or behind. Accounts start their weeks on different days, so the marker sits at
the mean, over known accounts, of the share of each account's week still to go
(`(resets_at - now) / 7 days`, clamped to 0-1). It uses the same accounts as the
weekly number: known accounts only. A window counted as reset (Pool rule 3), or one
with an unset reset at 0% used (the week hasn't started), contributes 1. If a known
account has usage but no reset time, the marker is hidden.

## Forecast

- Burn rate per account and window, over the last 30-60 min, smoothed (EWMA):
  `sum(rise in used%) / sum(time)` over consecutive readings in the same window. Two
  readings are in the same window when used% didn't drop and either their
  `resets_at` agree within 60 s (derived and upstream reset times jitter) or the
  earlier one was 0% with an unset reset. Other intervals are skipped and their time
  isn't counted. Taking the pool's used% instead would lose real burn whenever one
  account resets while others climb. `recent_requests` holds request counts only and
  isn't used.
- Demand is the sum of the account rates, in account-% per hour. The pool-share
  burn shown to the user is that sum divided by the account count; the simulation
  uses the undivided sum.
- Forward simulation of the 5-hour window, per minute, over the next 5 hours: split
  demand across usable accounts by the configured routing (strategy, weights and
  priority tiers; ocgo `forced_account` pins all demand to one account), apply known
  `resets_at`, start a new window on first use for idle accounts, and flag minutes
  with no usable account. When the routing isn't one the simulation models (session
  affinity on, for example), show no lockout forecast.
- Weekly run-out: each account's own weekly burn rate, extrapolated linearly to that
  account's weekly reset. Separate from the 5-hour simulation.
- Outputs, shown as text in the dropdown only: "lockout at 17:09 to 17:20", "safe
  for 5h", "weekly runs out Wed 18:00, resets Thu 09:00".
- History is chosen per provider. Claude and Codex use the fork's `quota/history`
  when the VM serves it and that provider isn't paused. On startup and wake the app
  fetches from its last stored observation (at least 1h, at most 720h back), so
  sleep leaves no gap. OpenCode Go, and Claude and Codex without the fork's poller,
  use the app's own readings, which have gaps while the Mac sleeps; gaps are kept as
  gaps, and the burn rate needs a few fresh readings after wake before it shows.

## Architecture

```
 cliproxy VM (NetBird)                          Mac
 ┌──────────────────────────┐                  ┌──────────────────────────────────┐
 │ CLIProxyAPI :8317        │◄─ mgmt key ──────┤ usage-monitor (Swift menubar app) │
 │  (management API)        │                  │  poll, dedupe, pool, forecast     │
 │ ocgo-proxy  :8320        │◄─ client token ──┤  SQLite history (30 days)         │
 └──────────────────────────┘                  │  Keychain: key and token          │
                                               └──────────────────────────────────┘
```

- **No server.** The app polls both proxies itself. Nothing is deployed on the VM;
  the only changes there are blocking the management paths at the public ingress and
  then enabling `allow-remote` (see Data sources).
- **Only client: the macOS menubar app**, native Swift with `NSStatusItem` (SwiftBar
  can't expand the item on click; a click always opens its menu). No web dashboard,
  statusline or T3 integration.
- **Setup screen**, shown on first launch and in Settings:
  - cliproxy URL. Accept the management page URL too and strip `/management.html`,
    as T3 does.
  - cliproxy management key, stored in the Keychain.
  - ocgo-proxy URL and client token (Keychain). Optional; without it the OpenCode Go
    row is hidden.
  - A "Test" button per source that makes one request and reports the result in
    words: wrong key, `allow-remote` off, untrusted TLS certificate (a private CA must
    be trusted in the macOS Keychain), timeout. It never retries a 401, because of the
    ban after five bad attempts.
  - Menubar icon: Normal or Compact (see Gauge design).
- **Polling budget.** Credential list every 60 s (cheap, and carries the passive
  `quota.signals`). The fork's `quota/history`, if served, every 60 s. ocgo status
  every 60 s (ocgo polls upstream itself).
- **Auth failures stop polling.** The first management 401, or a 403 for remote
  management disabled or a banned IP, stops all cliproxy requests and shows an auth
  error until the key changes or the user presses Test. Five failed polls would
  otherwise ban the Mac's IP for 30 min, again every 30 min. A provider 401 inside an
  `api-call` response affects only that account.
- **Active usage calls are off by default.** T3 Code's cliproxy usage reader, which
  uses these calls, never showed usage in this setup, so the cause is unknown. The app
  reads the passive signals and the fork's `quota/history`. Idle accounts show their
  last reading with its age. A setting turns the calls on once Phase 0 explains the
  T3 failure, and only if the fork's poller isn't running (it already polls
  Anthropic's usage endpoint every 5 min; a second poller doubles the load).
  Then: Claude/Codex usage through `api-call` only when an account's readings are
  older than ~5 min, at most every 5 min per account, backing off up to an hour after
  a 429.
- **Only poller.** T3 Code sends its Claude and Codex traffic through cliproxy as a
  custom endpoint, so it reads no usage itself, and no cliproxy usage source is
  configured in T3 (checked 2026-11-22). Leave it that way: adding one would make T3
  poll the same endpoints every 5 min.
- **Accounts by alias** in the UI (`claude-1`, `team-a`), with the email only in the
  hover detail.

### Reference: T3 Code's cliproxy usage reader

T3 Code (MIT, `apps/server/src/usage/cliproxyApi.ts`) reads usage from a cliproxy
hub. It never showed usage in this setup, so treat it as a reference for request
shapes, not as proof that they work against our fork:

- Settings: a usage-limit source `{ kind: "cliproxy", label, url, managementKey,
  enabled }`, with the key stored as a secret.
- `GET v0/management/auth-files` lists accounts (`id`, `auth_index`, `provider`,
  `email`, `disabled`, `id_token.chatgpt_account_id`, plan type). Disabled accounts
  and unknown providers are skipped.
- `POST v0/management/api-call` with `{ auth_index, method, url, header }` per
  account, 4 at a time, 15 s timeout. The response is `{ status_code, body }`; a
  non-2xx `status_code` means the provider refused, not that the hub failed.
- Claude: `GET https://api.anthropic.com/api/oauth/usage` with `Authorization:
  Bearer $TOKEN$`, `anthropic-beta: oauth-2025-04-20` and a `claude-code/…`
  User-Agent. Reads `five_hour`, `seven_day`, and model-scoped weekly limits from
  `limits[]` (`kind: "weekly_scoped"`), which our plans don't have.
- Codex: `GET https://chatgpt.com/backend-api/wham/usage` with `OpenAI-Beta:
  codex-1`, `Originator: Codex Desktop` and `Chatgpt-Account-Id`. Reads
  `rate_limit.primary_window` / `secondary_window` (`used_percent`, `reset_at`,
  `limit_window_seconds`).
- Identity: email and `chatgpt_account_id`.
- T3 also reads Grok and Antigravity accounts and can redeem Codex reset credits;
  out of scope here.

## Phases

| Phase | Scope | Done when |
|---|---|---|
| 0. Verify | First, check whether the public ingress forwards `/v0/management/*` and `/v8/management/*`, and whether `allow-remote` is already on; block the paths at the ingress before enabling it. Read the fork's source on thearch (`internal/quota`, routes, listing fields). Check that the live VM serves `GET /v8/management/quota/history` with per-account windows. Call the management API and `/_ocgo/status` once from the Mac and save sanitized samples as test fixtures. Record the routing strategy, weights, priority tiers, session affinity and ocgo `forced_account`. Check that Go account names are distinct workspaces, and look for Claude credential pairs that are the same subscription (legacy and hashed names). Separately, replay T3's `auth-files` and `api-call` requests by hand to find why T3 showed no usage (route, `allow-remote`, TLS, or the provider refusing), and record the live `oauth/usage` and `wham/usage` payloads if they come back. | Management paths unreachable through the public ingress; fixtures for every payload Phase 1 reads (credential list, `quota/history` if served, `/_ocgo/status`, routing and config); per-account windows available from passive signals or `quota/history`. Phase 1 can start then. Turning on active calls waits for the T3 failure to be explained and for `api-call` fixtures |
| 1. Core | Swift package: cliproxy and ocgo sources, normalization, dedupe, pool rules, SQLite history. Tests from the fixtures (equal-capacity pooling, duplicates, unknown accounts as a range, old readings and windows past their reset, Claude fraction units, a snapshot missing a window, zero-time resets, a Codex window with no length, blocked and unavailable accounts, an ocgo forced account, staggered resets, disabled accounts). | Pooled values match hand-computed ones on the fixtures; a test shows a 401 stops all cliproxy polling; SQLite history survives a restart and drops rows older than 30 days |
| 2. Menubar app | Setup screen, Normal/Compact menubar item, dropdown with the overlap line (E) for 5-hour and weekly, reset countdowns, weekly pace, hover detail, freshness. | Runs on the Mac against the live proxies, and by hand: Compact expands for 3 s and a second click opens the dropdown; key and token survive a relaunch from the Keychain; without ocgo the Go row is hidden |
| 3. Forecast | Burn rate, 5-hour simulation and weekly run-out, shown as text in the dropdown. | Backtest per provider on the fork's history or the app's own. For routing the simulation models: a lockout and recovery reproduced within 15 min, and no lockout predicted for a stretch when the usable pool stayed above 0; if the history has no lockout, a timestamped fixture with a labeled lockout and recovery stands in. For routing it doesn't model (session affinity on): a test shows the lockout forecast is withheld |

### Phase 0 findings (capture of 2026-11-23T03:16:02Z)

From the sanitized capture in `Tests/UsageCoreTests/Fixtures/live/`. Facts only,
except where marked "inferred".

Assumptions from `implementation-plan.md`:

- Payload shapes: the credential list, routing, config and ocgo status match this
  plan apart from the details added under Data sources. The fork's `quota/history`
  differs: account fields sit under `account`, readings are dated by `reading.at`,
  and windows are an array (see the cliproxy table).
- `quota.signals` values are plain strings.
- `quota/history`'s `account.id` equals the credential list's `id` for all five
  OAuth credentials. API-key ids (`claude:apikey:...`) appear only in
  `quota/history`.
- `success` and `failed` look cumulative (claude-ea14e983: 5712 and 34, against 167
  requests in its 20 `recent_requests` buckets). One capture can't show what a
  restart does, so that stays open.
- 403 bodies weren't captured; still open.
- The VM serves `GET /v8/management/quota/history?range=24h` (200), and
  `/v0/management/routing/strategy` and `/v0/management/config` answer 200.

Other observations:

- The fork's Claude `resetAt` has sub-second noise (`2026-11-23T07:00:00.3971Z`
  where the header says `1795417200`, 07:00:00Z), well inside the burn rate's 60 s
  tolerance.
- Fork readings and passive signals of the same window agree within a couple of
  points: codex user-3 shows 74% used in the 5-hour window and 24% weekly in both,
  codex user-2's 5-hour window is 6% in the fork and 4% passive, and claude user-4's
  weekly is 31% in the fork and 30% passive. Neither source is always the older one:
  user-2's passive reading (03:12:44) predates the fork's (03:15:11), while user-4's
  (03:16:02) is newer than the fork's (03:12:14).
- Go: `headroom` is 100 minus the highest window percent (team-a 0, team-b 33,
  extra 89). An unused `rolling` window at 0% reports `resets_at` 5 hours after
  `polled_at` (team-a: polled 03:14:11.57, resets 08:14:11.53), so (inferred) its
  reset moves with every poll, which the burn rate's "0% with an unset reset" case
  doesn't cover. `weekly` resets at 2026-11-30T00:00:00Z (a Monday) for all three
  accounts. Apart from extra's rolling window at 2%, only the monthly windows show
  use; team-b's monthly reset differs from the other two.

### P0.4 as captured

- Routing strategy: `weighted-round-robin` (`routing/strategy`, and
  `routing.strategy` in the config).
- Session affinity: on, `session-affinity-ttl: "4h"`. Per Forecast, routing the
  simulation doesn't model gets no lockout forecast, so T11b withholds it for
  Claude and Codex while affinity stays on. Burn rate and weekly run-out still show.
  Go routes by most headroom, has no affinity, and keeps its lockout forecast.
- Weights: only claude-ea14e983-user-4 sets one (`weight: 1`); the others default
  to 1. No credential is out of rotation.
- Priorities: Claude ea14e983-user-4 10, f5ae9dff-user-1 0, f5ae9dff-user-5 -10;
  Codex 85e5a20c-user-2 10, 85e5a20c-user-3 0. Each tier holds one credential, so
  (inferred) traffic goes to the highest-priority usable credential and weights
  don't matter yet. At capture time f5ae9dff-user-1 and -user-5 were quota-blocked
  until 04:20:12Z and 03:20:07Z.
- ocgo `forced_account`: the key is absent from `/_ocgo/status`, which the parser
  reads as not forced. The status can't tell "not forced" from "not reported".
- Go accounts: `team-a`, `team-b`, `extra`. At the same poll their monthly use
  differs (100% and rate-limited, 67%, 11%), so they are separate quotas (inferred:
  separate workspaces). team-a and extra share the monthly reset
  2026-11-30T21:54:01Z to the second.
- Claude pair: claude-f5ae9dff-user-1 and claude-f5ae9dff-user-5 share the hash
  `f5ae9dff`, have different emails, and have separate quotas. The fork read them
  21 ms apart at 03:12:11Z: weekly 83% left resetting 2026-11-29T23:00Z, and 64%
  left resetting 2026-11-26T07:00Z. No legacy `claude-<email>.json` file exists.
- Codex pair: codex-85e5a20c-user-2 and codex-85e5a20c-user-3 share the
  `chatgpt_account_id` (the sanitizer gives each real id its own fake, and both
  carry `...0001`) and the `85e5a20c` file hash, have different emails, and have
  separate quotas: weekly 57% left resetting 2026-11-24T02:11:16Z, and 76% left
  resetting 2026-11-27T11:58:55Z.
- Following the user's decision of 2026-11-23, identity moves to the seat: the key
  plus the email. These pairs are separate accounts, not aliases.

## Prior art

Reviewed 2026-11-22. Star counts and licenses checked with `gh api`; other details
come from READMEs and source, read by a research agent and spot-checked.

| Tool | Platform | Data source | Multiple accounts | Worth noting |
|---|---|---|---|---|
| [ai-usage-limit-monitor](https://github.com/vishnu09bharath/ai-usage-limit-monitor) (1★, MIT) | Swift menubar | Codex: drives `codex /status` in a PTY and parses the screen. Antigravity: local language server | No | Prototype, all commits on 2025-12-31. Supports Codex and Antigravity, no Claude. Menubar text turns orange below 25% and red below 15% |
| [openusage](https://github.com/robinebers/openusage) (4.6k★, MIT) | Swift macOS | Official endpoints, **CLIProxyAPI hubs** via management key | **Yes: "Unify Multiple Accounts"** | The only tool found that pools. Unified row: used summed up to each account's cap (so % averages), resets = earliest reset of any account, hover shows each account. Unified rows lose pace marks and "burning fast" |
| [CodexBar](https://github.com/steipete/CodexBar) (23k★, MIT) | Swift menubar, Linux Qt, CLI, widgets | Official endpoints, cookie and CLI fallbacks | Token accounts, segmented or stacked display | `UsagePace`: "on pace / in deficit / in reserve", run-out estimate, one alert per episode |
| [Cli-Proxy-API-Management-Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center) (4.8k★, MIT) | Web UI for CLIProxyAPI | `/v8/management` `api-call` to provider usage endpoints | One card per credential | Quota timeline with one lane per credential; no pooling, no forecast. Its parsers are a good reference for the payloads |
| [ClaudeBar](https://github.com/tddworks/ClaudeBar) (1.6k★, Apache-2.0) | Swift menubar | `claude /usage` PTY scrape or OAuth; `codex app-server` RPC | Several logins, shows the healthiest | "Runs out in 38m, 34m before it resets" |
| [llm-monitor](https://github.com/2AMLogic/llm-monitor) (23★, MIT) | Swift menubar, SQLite | 1-token `/v1/messages` ping, reads `anthropic-ratelimit-unified-*` headers | Many accounts | Headroom = 100 − max(5h %, weekly %), same as ocgo-proxy |
| Claude-Code-Usage-Monitor, ccstatusline, ccusage | TUI / statusline / CLI | Local JSONL logs, some `oauth/usage` | No | Burn-rate views; ccusage tracks cost and tokens, not quota |
| QuotaBar, AgentLimits, codex-minibar, Usage4Claude | Various | Provider quota APIs, cookies | Partly | Least-squares burn rate over 60 min (QuotaBar), "pacemaker" ring (AgentLimits), tray shows the most-used key (codex-minibar) |

What to take from them:

- openusage's pooling rule matches ours (average %, earliest reset, per-account
  detail on hover). Nobody forecasts a pooled lockout, which is the gap we fill.
- Pace marker on weekly gauges (CodexBar, AgentLimits, Usage4Claude).
- Least-squares burn rate over the last hour, needing a few readings before it shows
  (QuotaBar).
- Label every number's source and age.

Pitfalls they report:

- Anthropic throttles `/api/oauth/usage` hard. ClaudeBar caches for 15 min and backs
  off up to an hour after a 429. Several tools hitting it for the same login make it
  worse. That is why we read passive header signals first.
- Tokens expire and rotate. Through cliproxy that is the proxy's job, but
  `api-call` does not refresh, so a 401 means stale, not empty.
- PTY scraping and cookie access are fragile. We don't need either.

### Use openusage instead?

openusage already reads CLIProxyAPI hubs with a management key and pools accounts,
on macOS, which is now the same setup as ours. What it lacks:

- an ocgo-proxy source;
- the overlap gauge, the reset countdown and the compact icon;
- pace and forecast on unified rows.

Building our own is still the plan, but trying openusage on the Mac first is cheap and
gives a check on our numbers. Contributing an ocgo-proxy source to it is the
alternative if ours stalls.

## Decisions

- 2026-11-22: polling runs in the app; no collector service. The menubar app is the
  only client. No alerts; the app is informative only.
- 2026-11-22, after review: the menubar % is the 5-hour usable pool share. "Reset in
  5h" stays when every enabled subscription has full, usable 5-hour quota.
- 2026-11-23, after P0.3: account identity is the seat. Claude uses the hash plus
  the email, Codex the `chatgpt_account_id` plus the email, because team seats share
  the key but not the quota (see "P0.4 as captured"). T4b implements it.

## Open questions

None. Claude model-scoped weekly limits don't apply: our Claude plans don't include
Fable, so there are no per-model weekly caps (confirmed 2026-11-22).
