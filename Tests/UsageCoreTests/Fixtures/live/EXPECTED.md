# Expected pooled values

Worked out by hand from the live capture in this folder and the rules in
docs/plan.md ("Pool rules", "Reading passive signals", "Reading the status",
"Identity", with the seat identity decided after the capture: key plus
email). Nobody ran the app's code to get these numbers. The format is the one
described in `Fixtures/synthetic/T10/EXPECTED.md`.

as of: 2026-11-23T03:16:02Z

| provider | window  | known | quota     | usable    |
|----------|---------|-------|-----------|-----------|
| claude   | 5h      | 3/3   | 23        | 23        |
| claude   | weekly  | 3/3   | 72.3      |           |
| codex    | 5h      | 2/2   | 60        | 60        |
| codex    | weekly  | 2/2   | 66.5      |           |
| go       | 5h      | 3/3   | 99.3      | 66        |
| go       | weekly  | 3/3   | 100       |           |
| go       | monthly | 3/3   | 40.7      |           |

No identity alias is set. The capture has no legacy `claude-<email>.json` file and no
pair that plan.md asks Phase 0 to confirm.

## Working

Accounts that count:

- The credential list has six files. `antigravity-user-6@example.com.json` has a
  provider the app doesn't pool, so it gets no row. The other five have
  `disabled: false`.
- Identity is the seat: the key plus the email. Claude's key is the 8-hex hash in
  the file name: `ea14e983` (user-4), and `f5ae9dff` shared by user-1 and user-5.
  Those are different emails, so Claude has 3 accounts.
- Codex's key is `id_token.chatgpt_account_id`. Both Codex files carry
  `00000000-0000-4000-8000-000000000001`, with different emails (user-2 and user-3),
  so Codex has 2 accounts.
- The fork's `accounts[]` also lists three `claude:apikey:*` entries. None is in the
  credential list, so none is an account.
- Go has three account names: `team-a`, `team-b`, `extra`.
- Routing is `weighted-round-robin` with session affinity on. Every weight is 1 (the
  field is 1 on user-4 and missing elsewhere, and the default is 1), so no credential
  is out of rotation. Priorities (10, 0, -10) don't change who counts.

Readings. Each account and window keeps its newest reading, from the passive signals
or the fork, whichever is newer.

- Claude `ea14e983`: passive signals at 03:16:02.119 give 5h utilization 0.31 (69
  left, resets 07:00:00Z) and 7d utilization 0.3 (70 left, resets 2026-11-29T03:00Z).
  The fork's reading at 03:12:14.441 is older (short 69, weekly 69). Available.
- Claude `f5ae9dff` user-1: the fork read it at 03:12:11.489 (short 0, resets
  04:20:00; weekly 83). user-5: the fork read it at 03:12:11.510 (short 0, resets
  03:20:00; weekly 64). Both passive readings are older (01:18:13 and
  2026-11-22T23:28:07). Both files have `unavailable: true`, so neither is usable.
- Codex user-2: the fork read it at 03:15:11.909 (short 94, resets 08:04:31; weekly
  57, resets 2026-11-24T02:11:16Z). user-3: the fork read it at 03:13:03.679 (short
  26, resets 03:22:46; weekly 76). Both passive readings (03:12:44 and 01:54:09) are
  older. Both files are available.
- Go, polled at 03:14:11: `team-a` rolling 0 used, weekly 0 used, monthly
  `status: "rate-limited"` at 100 percent used (a rate-limited window is read: it is
  the limit team-a hit, and `exhausted_until` equals its reset), `available: false`.
  `team-b` rolling 0, weekly 0, monthly 67 used, available. `extra` rolling 2,
  weekly 0, monthly 11 used, available. No `forced_account`.

Rows:

- Claude 5h: (69 + 0 + 0) / 3 = 23. Usable: (69 + 0 + 0) / 3 = 23, because the two
  unavailable seats count 0 and already have 0 left.
- Claude weekly: (70 + 83 + 64) / 3 = 72.3.
- Codex 5h: (94 + 26) / 2 = 60. Both seats are available and neither weekly window
  is empty, so usable is 60.
- Codex weekly: (57 + 76) / 2 = 66.5.
- Go 5h: (100 + 100 + 98) / 3 = 99.3. Usable counts `team-a` as 0:
  (0 + 100 + 98) / 3 = 66.
- Go weekly: (100 + 100 + 100) / 3 = 100.
- Go monthly: (0 + 33 + 89) / 3 = 40.7.

No window is past its reset at 03:16:02. The nearest resets are Claude user-5's 5h
window at 03:20:00 and Codex user-3's at 03:22:46. Pool rule 3's reset proof is
therefore never needed.

History choice: the fork serves `quota/history`, and its Claude and Codex accounts
have `status: "ok"`, so both providers use the fork's history. Go uses the app's own
readings.

## Identity

The two `f5ae9dff` files have different emails, different 5h resets (04:20 and
03:20), different weekly resets (2026-11-29 and 2026-11-26) and different weekly
values (83 and 64). The two Codex files differ the same way (5h 94 and 26, weekly 57
and 76). They are separate seats sharing one organization or workspace id, so after
this capture identity became the seat (key plus email). Under the earlier rule
(key alone) the rows would have been Claude 5h 2/2 at 34.5, weekly 67, and Codex 5h
1/1 at 94, weekly 57.

Other readings that plan.md leaves open for this capture:

- Claude `ea14e983` weekly is 70 from the passive header and 69 from the fork four
  minutes earlier. The newest reading gives 72.3 for the pool. The fork value
  would give 72.
- The passive reading for `ea14e983` is stamped 03:16:02.119, which is 119 ms after
  the capture time above. The table still uses it.
- Go `team-a` monthly is `rate-limited` at 100 percent. Treating a non-`ok` window as
  unknown (plan.md before the capture) would give 2/3 known and the range 40.7-74.
