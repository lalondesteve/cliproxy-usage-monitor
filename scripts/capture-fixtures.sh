#!/usr/bin/env bash
# Capture sanitized fixtures from the live cliproxy management API and ocgo-proxy
# (task T2, run once for P0.3). Output goes to Tests/UsageCoreTests/Fixtures/live/.
#
# Run:
#   scripts/capture-fixtures.sh --ocgo-url http://<ocgo-host>:8320
#
# The script prompts (hidden input) for any secret that isn't already set:
#   CLIPROXY_MANAGEMENT_KEY  cliproxy management key
#   OCGO_TOKEN               ocgo-proxy client token
# Never pass a secret as an argument or type it into a command line: let the script
# prompt, or set the variable from a command that prints it, for example
#   OCGO_TOKEN="$(security find-generic-password -s ocgo -w)" scripts/capture-fixtures.sh ...
#
# Settings (environment variable or flag):
#   CLIPROXY_URL   --cliproxy-url  default http://cliproxy:8317
#   OCGO_URL       --ocgo-url      required
#   OUT_DIR        --out           default <repo>/Tests/UsageCoreTests/Fixtures/live
#   CLIPROXY_AUTH_HEADER           "bearer" (default) or "x-management-key"
#   CAPTURE_TIMEOUT                seconds per request, default 20
#   CAPTURE_CREDENTIALS_PATH       override the credential list path (see below)
#
# Behaviour:
#   - One request per endpoint, in this order: credential list, quota/history,
#     routing strategy, config, /_ocgo/status. No retries, no redirects, ~/.curlrc
#     ignored.
#   - The first 401 or 403 from either proxy stops the run before any other request
#     and exits 2 with nothing written. cliproxy bans an IP for 30 minutes after five
#     failed attempts, so a wrong key costs exactly one.
#   - Secrets reach curl through a config on stdin, never through argv, and are
#     removed from the environment before any child process starts.
#   - Raw responses live in a private temp dir that is deleted on exit. The config
#     response is filtered in a pipe down to its "routing" object and never touches
#     disk.
#   - Output is written only after the sanitizer's leak checks pass and a search of
#     the output for both secrets finds nothing. Files from a previous capture with
#     the same names are replaced; other files (EXPECTED.md) are left alone.
#
# Exit status: 0 all endpoints captured; 1 some endpoint failed (the others are
# written; see capture-manifest.json); 2 stopped on 401/403; 3 sanitizer or leak
# check refused to write; 64 usage error.

set -euo pipefail
set +a  # never auto-export, even if the caller's SHELLOPTS says so
# bash keeps the export flag of an inherited variable, so a caller that exported
# one of these names would hand the secret to every child. Clear the flag before
# any assignment. Function locals use "local +x" for the same reason.
declare +x cliproxy_key ocgo_token secret

# Copy the secrets into unexported shell variables and drop them from the
# environment before any external command runs, so no child process inherits them.
cliproxy_key="${CLIPROXY_MANAGEMENT_KEY:-}"
ocgo_token="${OCGO_TOKEN:-}"
unset CLIPROXY_MANAGEMENT_KEY OCGO_TOKEN

# Endpoint paths (from docs/plan.md). The credential list has an alternative,
# /v0/management/auth-files; set CAPTURE_CREDENTIALS_PATH to use it.
CREDENTIALS_PATH="${CAPTURE_CREDENTIALS_PATH:-/v8/management/credentials}"
QUOTA_HISTORY_PATH="/v8/management/quota/history?range=24h"
ROUTING_STRATEGY_PATH="/v0/management/routing/strategy"
CONFIG_PATH="/v0/management/config"
OCGO_STATUS_PATH="/_ocgo/status"

case "$0" in */*) script_dir="${0%/*}" ;; *) script_dir="." ;; esac
script_dir="$(cd "$script_dir" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
SANITIZER="$script_dir/sanitize_fixtures.py"

CLIPROXY_URL="${CLIPROXY_URL:-http://cliproxy:8317}"
OCGO_URL="${OCGO_URL:-}"
OUT_DIR="${OUT_DIR:-$repo_root/Tests/UsageCoreTests/Fixtures/live}"
CLIPROXY_AUTH_HEADER="${CLIPROXY_AUTH_HEADER:-bearer}"
CAPTURE_TIMEOUT="${CAPTURE_TIMEOUT:-20}"

OUTPUT_NAMES="cliproxy-credentials.json cliproxy-quota-history-24h.json
cliproxy-routing-strategy.json cliproxy-config-routing.json ocgo-status.json
capture-manifest.json"

die() { echo "capture-fixtures: $*" >&2; exit 64; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cliproxy-url) [[ $# -ge 2 ]] || die "--cliproxy-url needs a value"; CLIPROXY_URL="$2"; shift 2 ;;
    --ocgo-url) [[ $# -ge 2 ]] || die "--ocgo-url needs a value"; OCGO_URL="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a value"; OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    # Never echo an unknown argument: it may be a secret pasted in the wrong place.
    *) die "unknown argument (not shown; secrets are read from the environment or a prompt, never from arguments)" ;;
  esac
done

normalize_url() {
  local +x u="${1%/}"
  u="${u%/management.html}"
  echo "${u%/}"
}
CLIPROXY_URL="$(normalize_url "$CLIPROXY_URL")"
[[ -n "$OCGO_URL" ]] || die "ocgo-proxy URL is required (--ocgo-url or OCGO_URL)"
OCGO_URL="$(normalize_url "$OCGO_URL")"
for u in "$CLIPROXY_URL" "$OCGO_URL"; do
  [[ "$u" =~ ^https?:// ]] || die "each URL must start with http:// or https:// (value not shown)"
done
case "$CLIPROXY_AUTH_HEADER" in
  bearer) cliproxy_header_prefix="Authorization: Bearer " ;;
  x-management-key) cliproxy_header_prefix="X-Management-Key: " ;;
  *) die "CLIPROXY_AUTH_HEADER must be bearer or x-management-key" ;;
esac
command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"

# --- Secrets: prompt (hidden) for any that weren't in the environment ---
prompt_secret() { # SHELL_VAR ENV_NAME PROMPT
  local +x value="${!1}"
  if [[ -z "$value" ]]; then
    [[ -t 0 ]] || die "$2 is not set and stdin is not a terminal to prompt on"
    read -rs -p "$3: " value
    echo >&2
  fi
  [[ -n "$value" ]] || die "$2 is empty"
  case "$value" in
    *[[:cntrl:]]*) die "$2 contains control characters" ;;
  esac
  printf -v "$1" '%s' "$value"
}
prompt_secret cliproxy_key CLIPROXY_MANAGEMENT_KEY "cliproxy management key"
prompt_secret ocgo_token OCGO_TOKEN "ocgo-proxy client token"

# --- Private temp dir, removed on any exit ---
work="$(mktemp -d "${TMPDIR:-/tmp}/capture-fixtures.XXXXXX")"
chmod 700 "$work"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$work/raw" "$work/headers" "$work/out"

# curl_auth HEADER_LINE CURL_ARGS... : the header goes in through a config on stdin.
# printf is a builtin, so the secret is never in any process's argv.
curl_auth() {
  local +x esc="${1//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  shift
  printf 'header = "%s"\n' "$esc" |
    curl -q --config - --silent --show-error --globoff --proto '=http,https' \
      --connect-timeout 10 --max-time "$CAPTURE_TIMEOUT" "$@"
}

manifest_entries=""
failures=0

record() { # NAME PATH STATUS REQUESTED_AT
  local +x entry
  entry=$(printf '{"name": "%s", "path": "%s", "status": %s, "requested_at": "%s"}' "$1" "$2" "$3" "$4")
  manifest_entries="${manifest_entries:+$manifest_entries, }$entry"
}

# Status of the last response in a curl -D header dump. Servers end lines with CRLF
# and may omit the reason phrase ("HTTP/1.1 401\r"), so strip the CR and take
# exactly three digits. Prints nothing when no status line is found.
http_status() {
  local +x line code="" re='^HTTP/[0-9.]+ +([0-9][0-9][0-9])([^0-9]|$)'
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ $re ]]; then code="${BASH_REMATCH[1]}"; fi
  done <"$1"
  echo "$code"
}

# Mask both secrets in a string: raw, JSON-escaped, and Go-JSON-escaped.
redact() {
  local +x t="$1" s e g
  for s in "$cliproxy_key" "$ocgo_token"; do
    e="${s//\\/\\\\}"
    e="${e//\"/\\\"}"
    # Go's encoding/json also writes &, < and > as \u0026, \u003c and \u003e.
    g="${e//&/\\u0026}"
    g="${g//</\\u003c}"
    g="${g//>/\\u003e}"
    t="${t//"$g"/<secret>}"
    t="${t//"$e"/<secret>}"
    t="${t//"$s"/<secret>}"
  done
  printf '%s' "$t"
}

stop_run() { # MESSAGE...
  local +x line
  {
    for line in "$@"; do echo "$line"; done
    echo "  No further requests were made to either proxy, and nothing was written."
    echo "  cliproxy bans an IP for 30 min after 5 failed attempts; fix the cause before rerunning."
  } >&2
  exit 2
}

auth_stop() { # LABEL PATH STATUS [BODY_FILE]
  local +x body="" why
  # The body is how the user tells "remote management disabled" from "IP banned",
  # so print it, with both secrets masked before it is cut to 300 characters.
  if [[ -n "${4:-}" && -s "$4" ]]; then
    body="$(head -c 65536 "$4" | tr -d '\r')"
    body="$(redact "$body")"
    body="${body:0:300}"
  fi
  if [[ "$3" == 401 ]]; then
    why="  The key or token was rejected."
  else
    why="  Forbidden: remote management disabled (allow-remote), IP banned, or token rejected."
  fi
  stop_run "capture-fixtures: STOPPED: $1 answered HTTP $3 on $2." "$why" \
    ${body:+"  Response body: $body"}
}

# fetch NAME LABEL BASE PATH HEADER_LINE [routing]
fetch() {
  local +x name="$1" label="$2" base="$3" path="$4" header="$5" mode="${6:-}"
  local +x hdr="$work/headers/$name" body="$work/raw/$name.json" when rc=0 xrc=0 status
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  if [[ "$mode" == routing ]]; then
    curl_auth "$header" -D "$hdr" -o - "$base$path" |
      python3 -I "$SANITIZER" extract-routing >"$body" 2>"$work/extract.err"
    local +x ps=("${PIPESTATUS[@]}")
    rc="${ps[0]}" xrc="${ps[1]}"
  else
    curl_auth "$header" -D "$hdr" -o "$body" "$base$path"
    rc=$?
  fi
  set -e
  status="$(http_status "$hdr")"
  if [[ "$status" == 401 || "$status" == 403 ]]; then
    auth_stop "$label" "$path" "$status" "$( [[ "$mode" == routing ]] || echo "$body")"
  fi
  if [[ $rc -eq 0 && -z "$status" ]]; then
    # A response arrived but its status can't be read, so a rejected key can't be
    # ruled out. Stop rather than risk more failed attempts.
    stop_run "capture-fixtures: STOPPED: $label $path: response has no readable HTTP status line."
  fi
  if [[ $rc -ne 0 || -z "$status" ]]; then
    echo "capture-fixtures: $label $path: request failed (curl exit $rc); continuing" >&2
    record "$name" "$path" '"request-failed"' "$when"
    rm -f "$body"; failures=$((failures + 1)); return 0
  fi
  if [[ "$status" != 200 ]]; then
    echo "capture-fixtures: $label $path: HTTP $status; not written, continuing" >&2
    record "$name" "$path" "$status" "$when"
    rm -f "$body"; failures=$((failures + 1)); return 0
  fi
  if [[ "$mode" == routing && $xrc -ne 0 ]]; then
    echo "capture-fixtures: $label $path: $(cat "$work/extract.err"); not written" >&2
    record "$name" "$path" '"unparseable"' "$when"
    rm -f "$body"; failures=$((failures + 1)); return 0
  fi
  [[ "$mode" == routing && -s "$work/extract.err" ]] && cat "$work/extract.err" >&2
  record "$name" "$path" "$status" "$when"
  echo "capture-fixtures: $label $path: HTTP 200" >&2
}

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fetch cliproxy-credentials cliproxy "$CLIPROXY_URL" "$CREDENTIALS_PATH" "$cliproxy_header_prefix$cliproxy_key"
fetch cliproxy-quota-history-24h cliproxy "$CLIPROXY_URL" "$QUOTA_HISTORY_PATH" "$cliproxy_header_prefix$cliproxy_key"
fetch cliproxy-routing-strategy cliproxy "$CLIPROXY_URL" "$ROUTING_STRATEGY_PATH" "$cliproxy_header_prefix$cliproxy_key"
fetch cliproxy-config-routing cliproxy "$CLIPROXY_URL" "$CONFIG_PATH" "$cliproxy_header_prefix$cliproxy_key" routing
fetch ocgo-status ocgo-proxy "$OCGO_URL" "$OCGO_STATUS_PATH" "Authorization: Bearer $ocgo_token"

printf '{"captured_at": "%s", "endpoints": [%s]}\n' "$started" "$manifest_entries" \
  >"$work/raw/capture-manifest.json"

# The sanitizer gets the secrets on stdin and refuses to write if either appears in
# any decoded JSON key or value (so an escaped echo like k\"x is caught too).
printf '%s\n%s\n' "$cliproxy_key" "$ocgo_token" |
  python3 -I "$SANITIZER" sanitize "$work/raw" "$work/out" || exit 3

# Second, independent check on the raw bytes of the output.
for secret in "$cliproxy_key" "$ocgo_token"; do
  if printf '%s\n' "$secret" | grep -rqF -f - "$work/out"; then
    echo "capture-fixtures: a secret appears in the sanitized output; nothing written" >&2
    exit 3
  fi
done

mkdir -p "$OUT_DIR"
for f in $OUTPUT_NAMES; do rm -f "$OUT_DIR/$f"; done
cp "$work/out/"*.json "$OUT_DIR/"
echo "capture-fixtures: wrote $(ls "$work/out" | wc -l | tr -d ' ') files to $OUT_DIR" >&2

if [[ $failures -gt 0 ]]; then
  echo "capture-fixtures: $failures endpoint(s) failed; see capture-manifest.json" >&2
  exit 1
fi
