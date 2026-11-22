# T7 synthetic fixtures

`/_ocgo/status` bodies shaped like plan.md "ocgo-proxy". Expected values come from
plan.md "Reading the status" and the worked examples in docs/implementation-plan.md.

- `e9-never-polled.json`: E9. `team-fresh` has no `polled_at`, headroom 100 and every
  window `ok` at 0%; `team-zero` has Go's zero time as `polled_at`. Both are unknown
  (no readings). `team-a` is a normal polled account for contrast.
- `e10-forced.json`: E10. `forced_account: team-b`; team-b is `available: false` with
  a future `cooldown_until` but its windows are fine. team-a is `notForcedAccount`,
  team-b is usable.
- `e16-1150.json`, `e16-1202.json`: E16's two raw responses. 11:50: rolling 60% and
  weekly 30%, both resetting at 12:00. 12:02: rolling `ok` at 5%; weekly
  `status: "error"`, `percent: 0`, next week's `resets_at`. No `monthly` key, which
  the parser must tolerate.
- `past-reset.json`: fetched at 12:05; rolling resets at 12:00 but `polled_at` is
  11:50. The 60% reading comes out unchanged with `observedAt` 11:50, not 0%.
- `poll-error.json`: team-a keeps its last good windows from 11:40 with a
  `poll_error`; team-b failed its first poll (no `polled_at`); team-c has a
  `poll_error` and every window in `status: "error"`.
- `status-not-ok.json`: windows with `error`, a missing status, `unknown`, `OK`
  (wrong case) and `ok` without `percent`. Only team-a's rolling 30% is read.
- `availability.json`: one account per availability case, taken at 12:00.
- `three-windows.json`: `rolling`, `weekly`, `monthly` map to 5-hour, weekly, monthly;
  an unknown `daily` window is ignored; percents outside 0...100 are clamped.
