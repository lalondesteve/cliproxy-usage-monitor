# T11d backtest fixtures

There is no real history with a lockout yet, so these stand in (plan.md Phase 3). Each
provider has one timestamped history with a labeled lockout and recovery, then a long
stretch where the pool stays above 0. The scenarios were worked out by hand below;
`make_fixtures.py` adds up the per-interval usage written here and checks the
checkpoints, and does not call the app's simulation.

Files:

- `<provider>.csv`: one 5-hour reading per account every 5 minutes, as the store keeps
  them (`observed_at`, `file_key`, `window`, `used_percent`, `resets_at` (empty =
  unset), `source`). Only 5-hour windows; no weekly or monthly readings, so nothing is
  weekly-blocked.
- `scenarios.json`: per provider the routing, the history the forecast reads (`fork`
  or `local`), the accounts, the replay range and the labels.

Labels (UTC, 2026-11-22):

| provider | routing | history | lockout (start, end) | pool above 0 |
|---|---|---|---|---|
| claude | round-robin | fork (`forkPoller`) | 10:30 to 11:30 | 08:00-10:30, 11:30-19:00 |
| codex | fill-first | local (`passive`) | 09:30 to 10:30 | 08:00-09:30, 10:30-17:25 |
| go | most-headroom | local (`ocgo`) | 09:40 to 10:40 | 08:00-09:40, 10:40-17:40 |

A lockout starts at the first sample where every account is at 100% used, and ends
when the first empty account's 5-hour window resets.

Demand is "account-% per 5 minutes" over the whole pool and alternates between a low
and a high interval, starting low at 08:00, so the burn rate the app measures is never
exactly the true average. When requests can't be served (lockout) nothing is used.
After recovery the demand drops to 1 per 5 minutes (12%/h).

## Claude: round-robin, two accounts

Start: a 10% used, resets 12:00; b 40% used, resets 11:30. Demand 4, 6, 4, 6, ... (1
per minute on average), half to each usable account.

- 08:00-10:00: a and b each +5 per 10 minutes. b reaches 100 at 10:00
  (40 + 12 x 5); a is at 70.
- 10:00-10:30: b is empty, a takes all: 4 + 6 + 4 + 6 + 4 + 6 = 30, so a reaches
  100 at 10:30. **Lockout starts 10:30.**
- 11:30: b resets (a resets later, at 12:00). **Lockout ends 11:30.** b's new window
  starts with the first request: resets 16:30.
- 11:30-12:00: b alone, +1 per 5 min: 6 at 12:00. 12:00: a resets, new window to
  17:00. Then +0.5 each per 5 min: a 27 and b 33 at 16:30, b resets (to 21:30); a 30
  at 17:00, a resets (to 22:00); at 19:00 a 12, b 15.

## Codex: fill-first, two accounts

Start: codex-1 40% used, resets 12:30; codex-2 70% used, resets 10:30. Demand 4, 6, ...
(1 per minute), all to the first usable credential by file name.

- 08:00-09:00: codex-1 takes 60 and reaches 100 at 09:00.
- 09:00-09:30: codex-2 takes 30 and reaches 100 at 09:30. **Lockout starts 09:30.**
- 10:30: codex-2 resets. **Lockout ends 10:30.** New window to 15:30.
- 10:30-12:30: codex-2 +1 per 5 min: 24 at 12:30. 12:30: codex-1 resets (to 17:30)
  and, being first, takes everything: 36 at 15:30, 59 at 17:25. codex-2 resets at
  15:30 and stays idle (0%, reset unset).

## Go: most-headroom, two accounts

Start: team-a 28% used (72 left), resets 13:00; team-b 52% used (48 left), resets
10:40. Demand 5, 7, 5, 7, ... (1.2 per minute), to the account with the most left,
split evenly once they are level.

- 08:00-08:20: team-a takes 5 + 7 + 5 + 7 = 24 and is level with team-b at 48 left.
- 08:20-09:40: both drain together, 6 each per 10 minutes, and reach 100 used at
  09:40 (52 + 8 x 6). **Lockout starts 09:40.**
- 10:40: team-b resets. **Lockout ends 10:40.** New window to 15:40.
- 10:40-13:00: team-b +1 per 5 min: 28 at 13:00. 13:00: team-a resets (to 18:00) and
  has more left, so it takes everything until it is level at 28 used (15:20). Both
  +0.5 per 5 min to 30 at 15:40. 15:40: team-b resets (to 20:40) and takes everything:
  24 at 17:40.

## What the backtest expects (Backtest, T11dBacktestTests)

- The observed lockouts the harness finds in each history equal the label, and none
  is left running.
- Every forecast made from the third sample (08:10) up to the end of the lockout
  reproduces it within 15 minutes, start (clipped to the forecast time during the
  lockout) and end. The 08:00 and 08:05 forecasts have too few readings.
- Every forecast made in the stretch where the pool stayed above 0 for the hour
  before it and the 5 hours after it is `safe`: claude 12:30-14:00, codex 11:30-12:25,
  go 11:40-12:40. No forecast anywhere in the histories is a false alarm or a miss,
  including the late ones whose 5 hours run past the last reading: those are judged
  as far as the readings go.
- Replayed only to 09:00, the Claude history still shows the 10:30 lockout, but it
  starts after the replayed range and isn't checked.

Accounts routing can't use and gaps from a sleeping Mac aren't in these histories;
T11dHandHistoryBacktestTests writes short histories for those by hand.
