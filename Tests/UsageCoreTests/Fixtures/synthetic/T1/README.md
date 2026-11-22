# T1 synthetic fixtures

`ocgo-status.json`: a `/_ocgo/status` body shaped like plan.md "ocgo-proxy". Three
accounts with `rolling` used 52, 40 and 64, so the pooled 5-hour remaining is
(48 + 60 + 36) / 3 = 48%. Also exercises a nanosecond `polled_at` (team-a), a
`+00:00` offset (team-b) and Go's zero time as an unset reset (team-c).
