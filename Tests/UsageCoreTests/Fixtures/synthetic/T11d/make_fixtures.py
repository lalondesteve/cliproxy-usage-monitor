#!/usr/bin/env python3
"""Writes the T11d backtest fixtures (<provider>.csv) from the hand-worked scenarios in
README.md. Run from this folder: python3 make_fixtures.py

Each scenario lists, per 5-minute interval, how much 5-hour quota each account uses
(the routing split worked out by hand in README.md, not by the app's simulation), and
the resets that happen at a sample time. The script only adds those numbers up and
checks the hand-worked checkpoints, so a slip in either shows up here.
"""
import csv
from datetime import datetime, timedelta, timezone

DAY = datetime(2026, 11, 22, tzinfo=timezone.utc)
STEP = timedelta(minutes=5)


def at(hhmm):
    h, m = map(int, hhmm.split(":"))
    return DAY + timedelta(hours=h, minutes=m)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ") if d else ""


def alternating(low, high, since):
    """Pool demand per 5-minute interval: `low` for the interval starting at `since`,
    then `high`, `low`, ... (average (low + high) / 2 per interval)."""
    def demand(t):
        return low if ((t - at(since)) // STEP) % 2 == 0 else high
    return demand


def run(name, accounts, start, end, split, resets, checks, source):
    """accounts: {key: (fileKey, used, resetsAt)}; split(t) -> {key: used% added over
    [t, t + 5 min)}; resets: {time: {key: new resetsAt or None}} (used% back to 0);
    checks: {time: {key: expected used%}} at that sample, before its resets."""
    state = {k: [used, reset] for k, (_, used, reset) in accounts.items()}
    rows = []
    t = at(start)
    while t <= at(end):
        for k, want in checks.get(t, {}).items():
            assert abs(state[k][0] - want) < 1e-9, f"{name} {iso(t)} {k}: {state[k][0]} != {want}"
        for k, reset in resets.get(t, {}).items():
            state[k] = [0.0, reset]
        for k, (file_key, _, _) in accounts.items():
            used, reset = state[k]
            rows.append([iso(t), file_key, "fiveHour", f"{used:g}", iso(reset), source])
        for k, add in split(t).items():
            state[k][0] += add
            assert state[k][0] <= 100 + 1e-9, f"{name} {iso(t)} {k} over 100"
        t += STEP
    with open(f"{name}.csv", "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["observed_at", "file_key", "window", "used_percent", "resets_at", "source"])
        w.writerows(rows)


# Claude: round-robin, fork history. Pool demand 4 and 6 (account-% per 5 min)
# alternating from 08:00, half to each usable account.
claude_demand = alternating(4, 6, "08:00")


def claude_split(t):
    if t < at("10:00"):
        return {"a": claude_demand(t) / 2, "b": claude_demand(t) / 2}   # both usable
    if t < at("10:30"):
        return {"a": claude_demand(t)}                                  # b empty
    if t < at("11:30"):
        return {}                                                       # lockout
    if t < at("12:00"):
        return {"b": 1}                                                 # a empty, 0.2/min
    return {"a": 0.5, "b": 0.5}


run("claude",
    {"a": ("claude-aaaa1111-a@example.com.json", 10.0, at("12:00")),
     "b": ("claude-bbbb2222-b@example.com.json", 40.0, at("11:30"))},
    "08:00", "19:00", claude_split,
    resets={at("11:30"): {"b": at("16:30")}, at("12:00"): {"a": at("17:00")},
            at("16:30"): {"b": at("21:30")}, at("17:00"): {"a": at("22:00")}},
    checks={at("10:00"): {"a": 70, "b": 100}, at("10:30"): {"a": 100, "b": 100},
            at("11:30"): {"a": 100, "b": 100}, at("12:00"): {"a": 100, "b": 6},
            at("16:30"): {"a": 27, "b": 33}, at("17:00"): {"a": 30, "b": 3},
            at("19:00"): {"a": 12, "b": 15}},
    source="forkPoller")

# Codex: fill-first (codex-1 before codex-2), local history (passive). Pool demand 4
# and 6 alternating from 08:00.
codex_demand = alternating(4, 6, "08:00")


def codex_split(t):
    if t < at("09:00"):
        return {"c1": codex_demand(t)}
    if t < at("09:30"):
        return {"c2": codex_demand(t)}                                  # c1 empty
    if t < at("10:30"):
        return {}                                                       # lockout
    if t < at("12:30"):
        return {"c2": 1}                                                # c1 empty, 0.2/min
    return {"c1": 1}                                                    # c1 first again


run("codex",
    {"c1": ("codex-1@example.com.json", 40.0, at("12:30")),
     "c2": ("codex-2@example.com.json", 70.0, at("10:30"))},
    "08:00", "17:25", codex_split,
    resets={at("10:30"): {"c2": at("15:30")}, at("12:30"): {"c1": at("17:30")},
            at("15:30"): {"c2": None}},
    checks={at("09:00"): {"c1": 100, "c2": 70}, at("09:30"): {"c1": 100, "c2": 100},
            at("10:30"): {"c1": 100, "c2": 100}, at("12:30"): {"c1": 100, "c2": 24},
            at("15:30"): {"c1": 36, "c2": 24}, at("17:25"): {"c1": 59, "c2": 0}},
    source="passive")

# Go: ocgo most-headroom, local history (ocgo). Pool demand 5 and 7 alternating from
# 08:00, to the account(s) with the most headroom.
go_demand = alternating(5, 7, "08:00")


def go_split(t):
    if t < at("08:20"):
        return {"a": go_demand(t)}                                      # a has more left
    if t < at("09:40"):
        return {"a": go_demand(t) / 2, "b": go_demand(t) / 2}           # level, together
    if t < at("10:40"):
        return {}                                                       # lockout
    if t < at("13:00"):
        return {"b": 1}                                                 # a empty, 0.2/min
    if t < at("15:20"):
        return {"a": 1}                                                 # a fresh: 100 > 72
    if t < at("15:40"):
        return {"a": 0.5, "b": 0.5}                                     # level at 72 left
    return {"b": 1}                                                     # b fresh: 100 > 70


run("go",
    {"a": ("team-a", 28.0, at("13:00")), "b": ("team-b", 52.0, at("10:40"))},
    "08:00", "17:40", go_split,
    resets={at("10:40"): {"b": at("15:40")}, at("13:00"): {"a": at("18:00")},
            at("15:40"): {"b": at("20:40")}},
    checks={at("08:20"): {"a": 52, "b": 52}, at("09:40"): {"a": 100, "b": 100},
            at("10:40"): {"a": 100, "b": 100}, at("13:00"): {"a": 100, "b": 28},
            at("15:20"): {"a": 28, "b": 28}, at("15:40"): {"a": 30, "b": 30},
            at("17:40"): {"a": 30, "b": 24}},
    source="ocgo")
