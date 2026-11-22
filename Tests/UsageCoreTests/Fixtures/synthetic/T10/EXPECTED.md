# Expected pooled values

Synthetic stand-in for `Fixtures/live/EXPECTED.md`, so the T10 fixture replay test
runs on a known capture until P0.3 lands. The other files here use the names
`scripts/capture-fixtures.sh` writes. Values were worked out by hand from plan.md
"Pool rules", not by running the code.

Format (read by `T10ExpectedSheet` in T10FixtureReplayTests.swift; any other line is a
comment):

- `as of: <RFC 3339>`: the capture time. The replay's clock is fixed here.
- `alias: <fileKey> = <identity>`: optional, one per Settings identity alias.
- A table with a header row naming its columns. `provider` (claude, codex, go),
  `window` (5h, weekly, monthly) and `quota` are required; `known` ("2/3") and
  `usable` are optional. Every row has a cell for every column and a non-empty
  `quota`. A percent is `55` or a range `40-73.3`; `-` means no value (no known or
  enabled account); an empty `known` or `usable` cell isn't checked. Percents match
  within 0.5 points, so whole-number hand rounding passes.

as of: 2026-11-22T12:00:00Z

| provider | window  | known | quota     | usable    |
|----------|---------|-------|-----------|-----------|
| claude   | 5h      | 2/3   | 40-73.3   | 40-73.3   |
| claude   | weekly  | 2/3   | 46.7-80   |           |
| codex    | 5h      | 1/1   | 75        | 75        |
| codex    | weekly  | 1/1   | 90        |           |
| go       | 5h      | 2/2   | 55        | 55        |
| go       | weekly  | 2/2   | 65        |           |
| go       | monthly | 2/2   | 75        |           |

Working:

- Claude: `aaaa1111` passive 5h 0.30 and 7d 0.40 at 11:58 (70 and 60 left);
  `bbbb2222` from the fork's `current` at 11:55 (short 50, weekly 80 left);
  `cccc3333` has no reading, so it's unknown (0 then 100). 5h: (70+50+0)/3 = 40 to
  (70+50+100)/3 = 73.3. Weekly: (60+80)/3 = 46.7 to (60+80+100)/3 = 80. Every account
  is available and none is weekly-blocked, so usable equals quota.
- Codex: one account, 5-hour window (300 min) 25 used, weekly (10080 min) 10 used.
- Go: team-a 60/20/10 used, team-b 30/50/40 used, both polled at 11:58 and available.
  5h (40+70)/2 = 55, weekly (80+50)/2 = 65, monthly (90+60)/2 = 75.
- Every reading is 2 to 5 minutes old at 12:00 and before its reset.
