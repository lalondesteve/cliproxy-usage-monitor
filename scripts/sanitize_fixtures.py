#!/usr/bin/env python3
"""Sanitize raw proxy responses into committable fixtures (task T2).

Stdlib only. Called by scripts/capture-fixtures.sh; usable on its own:

  sanitize_fixtures.py extract-routing < config.json > routing.json
      Read a cliproxy config response on stdin and print {"routing": <object>}.
      Nothing else from the config is printed.

  sanitize_fixtures.py sanitize RAW_DIR OUT_DIR < secrets
      Sanitize every RAW_DIR/*.json into OUT_DIR/ with the same file name. Secrets
      (one per line on stdin) must not appear in any decoded output string. One email
      map and one chatgpt_account_id map are shared by all files, so joins across
      endpoints still match. Output is checked for leaks before anything is written;
      on a leak nothing is written and the exit status is 3.

Rules:
  - Emails become user-N@example.com, numbered by sorted real address, so a rerun
    over the same accounts gives the same numbers. Emails inside credential file
    names are replaced in place, so "claude-1a2b3c4d-<email>.json" keeps its hash.
  - Token-like keys are dropped (access_token, refresh_token, id_token, API keys,
    secrets, passwords, Authorization and Cookie headers). An id_token object keeps
    only chatgpt_account_id (faked) and the plan type; an id_token string is dropped.
  - chatgpt_account_id values get a stable fake UUID, replaced wherever the real
    value appears (including a Chatgpt-Account-Id header in quota.signals).
  - String values that look like credentials (JWTs, sk-..., Bearer ...) become
    "REDACTED".
  - Other keys are never renamed, so header names keep their casing.

Error messages never include response content.
"""

import json
import os
import re
import sys

REDACTED = "REDACTED"
FAKE_DOMAIN = "example.com"

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z0-9-]{2,}")
FULL_EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}$")
# Credential file name prefix in front of an email: "claude-1a2b3c4d-", "codex-".
CRED_PREFIX_RE = re.compile(
    r"^(?:claude|codex|gemini|qwen|iflow|antigravity|vertex|aistudio|kimi|openai|anthropic)"
    r"-(?:[0-9a-f]{8}-)?",
    re.IGNORECASE,
)
FILE_EXT_RE = re.compile(r"\.json$", re.IGNORECASE)

SECRET_VALUE_RE = re.compile(
    r"eyJ"  # JWT header prefix, anywhere in the string
    r"|^\s*(?:sk-|sk_|rk-|rt_|pk_live|ghp_|gho_|github_pat_|xox[abpr]-|AIza|ya29\.)"
    r"|^\s*Bearer\s",
)

# Normalized key names (lowercase, no "-", "_", " ") that are always dropped.
TOKEN_KEYS_EXACT = {
    "key", "keys", "token", "tokens", "secret", "secrets", "password", "passwd",
    "authorization", "proxyauthorization", "cookie", "setcookie", "session",
    "sessionkey", "privatekey", "clientsecret", "managementkey", "credential",
}
TOKEN_KEY_SUFFIXES = ("token", "secret", "password", "apikey", "privatekey", "authorization")
TOKEN_KEY_PARTS = ("apikey", "secretkey", "accesskey", "accesstoken", "refreshtoken")

ID_TOKEN_KEY = "idtoken"
ID_TOKEN_KEEP = {"chatgpt_account_id", "plan_type", "chatgpt_plan_type"}
ACCOUNT_ID_KEY = "chatgptaccountid"


def norm_key(key):
    return re.sub(r"[-_\s]", "", str(key)).lower()


def is_token_key(key):
    k = norm_key(key)
    if k in TOKEN_KEYS_EXACT:
        return True
    if k.endswith(TOKEN_KEY_SUFFIXES):
        return True
    return any(part in k for part in TOKEN_KEY_PARTS)


def looks_secret(value):
    return bool(SECRET_VALUE_RE.search(value))


def _email_candidates(text, known):
    """Emails found in text, with credential-name decoration trimmed off.

    The "<provider>-<8hex>-" prefix and ".json" suffix of a credential file name are
    removed first, then the whole remaining address is the email. A plain address
    already seen in an email field is taken as is, so "codex-bob@x.com" as an email
    value isn't cut down to "bob@x.com".
    """
    found = []
    for match in EMAIL_RE.finditer(text):
        cand = FILE_EXT_RE.sub("", match.group(0))
        local, _, domain = cand.partition("@")
        labels = domain.split(".")
        last = labels[-1]
        # TLDs never contain "-" (bar IDN "xn--"), so "outlook.com-plus" is the
        # codex file name's plan suffix glued onto the domain.
        if "-" in last and not last.lower().startswith("xn--"):
            labels[-1] = last.split("-", 1)[0]
        domain = ".".join(labels)
        whole = (local + "@" + domain).lower()
        if whole in known:
            found.append(whole)
        else:
            found.append((CRED_PREFIX_RE.sub("", local) + "@" + domain).lower())
    return found


def _walk_strings(node, visit, key=None):
    """Call visit(string, key) for every dict key (key=None) and string value.

    A string inside a list gets the key of the list, so a Go http.Header value
    like {"Chatgpt-Account-Id": ["..."]} is still seen under its header name.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            visit(str(k), None)
            _walk_strings(v, visit, k)
    elif isinstance(node, list):
        for v in node:
            _walk_strings(v, visit, key)
    elif isinstance(node, str):
        visit(node, key)


class Sanitizer:
    """Builds the run-wide email and account-id maps from every document of a run."""

    def __init__(self, docs):
        known = set()
        account_ids = set()

        def full_emails_and_ids(s, key):
            if FULL_EMAIL_RE.match(s) and not FILE_EXT_RE.search(s):
                known.add(s.lower())
            if key is not None and norm_key(key) == ACCOUNT_ID_KEY and s:
                account_ids.add(s)

        for doc in docs:
            _walk_strings(doc, full_emails_and_ids)

        # Second pass: emails embedded in other strings (credential file names),
        # matched against the plain addresses found above.
        emails = set(known)

        def embedded(s, _key):
            emails.update(_email_candidates(s, known))

        for doc in docs:
            _walk_strings(doc, embedded)

        self._email_map = {
            real: "user-%d@%s" % (i, FAKE_DOMAIN)
            for i, real in enumerate(sorted(emails), start=1)
        }
        self._account_map = {
            real: "00000000-0000-4000-8000-%012d" % i
            for i, real in enumerate(sorted(account_ids), start=1)
        }
        # Longest first so a short value never rewrites part of a longer one.
        self._email_res = [
            (re.compile(re.escape(e), re.IGNORECASE), self._email_map[e])
            for e in sorted(self._email_map, key=len, reverse=True)
        ]
        self._account_order = sorted(self._account_map, key=len, reverse=True)

    def replace_text(self, s):
        if s in self._account_map:
            return self._account_map[s]
        for real in self._account_order:
            if len(real) >= 6 and real in s:
                s = s.replace(real, self._account_map[real])
        if "@" in s:
            for rx, fake in self._email_res:
                s = rx.sub(fake, s)
        return s

    def _value(self, v):
        if isinstance(v, dict):
            return self._dict(v)
        if isinstance(v, list):
            return [self._value(x) for x in v]
        if isinstance(v, str):
            if looks_secret(v):
                return REDACTED
            return self.replace_text(v)
        return v

    def _dict(self, d):
        out = {}
        for k, v in d.items():
            nk = norm_key(k)
            if nk == ID_TOKEN_KEY:
                if isinstance(v, dict):
                    kept = {ik: iv for ik, iv in v.items() if ik in ID_TOKEN_KEEP}
                    out[self.replace_text(str(k))] = self._dict(kept)
                continue  # an id_token string (the JWT itself) is dropped
            if is_token_key(k):
                continue
            out[self.replace_text(str(k))] = self._value(v)
        return out

    def sanitize(self, doc):
        return self._value(doc)


# Leak checks run on the serialized output, independent of the rules above.
AT_TOKEN_RE = re.compile(r"@([A-Za-z0-9.-]*)")
ALLOWED_AT_RE = re.compile(r"^example\.com(?:-[A-Za-z0-9-]*)?$")


def find_leaks(text):
    problems = []
    if "eyJ" in text:
        problems.append("JWT prefix 'eyJ'")
    for m in AT_TOKEN_RE.finditer(text):
        domain = FILE_EXT_RE.sub("", m.group(1))
        if not ALLOWED_AT_RE.match(domain):
            problems.append("'@' not followed by example.com")
            break
    return problems


def find_secrets(node, secrets, path="$"):
    """Paths of decoded strings (keys or values) that contain any of the secrets."""
    hits = []

    def visit(text, _key):
        if any(sec in text for sec in secrets):
            hits.append(path)

    if secrets:
        _walk_strings(node, visit)
    return hits


def find_token_keys(node, path="$"):
    hits = []
    if isinstance(node, dict):
        for k, v in node.items():
            if is_token_key(k) and norm_key(k) != ID_TOKEN_KEY:
                hits.append("%s.%s" % (path, k))
            hits.extend(find_token_keys(v, "%s.%s" % (path, k)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            hits.extend(find_token_keys(v, "%s[%d]" % (path, i)))
    return hits


def dumps(doc):
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def sanitize_documents(docs, secrets=()):
    """docs: {name: parsed JSON}. Returns {name: sanitized JSON}. Raises ValueError on leak.

    secrets: strings that must not appear in any decoded key or value of the output
    (the management key and ocgo token), checked after JSON decoding so an escaped
    form like k\\"x still counts.
    """
    secrets = [x for x in secrets if x]
    s = Sanitizer([docs[name] for name in sorted(docs)])
    out = {name: s.sanitize(docs[name]) for name in sorted(docs)}
    problems = []
    for name, doc in out.items():
        for p in find_leaks(dumps(doc)):
            problems.append("%s: %s" % (name, p))
        for path in find_token_keys(doc):
            problems.append("%s: token-like key at %s" % (name, path))
        if find_secrets(doc, secrets):
            problems.append("%s: contains the management key or ocgo token" % name)
    if problems:
        raise ValueError("refusing to write, sanitized output still leaks:\n  " + "\n  ".join(problems))
    return out


def extract_routing(stream_in, stream_out):
    try:
        cfg = json.load(stream_in)
    except ValueError:
        sys.stderr.write("extract-routing: config response is not JSON\n")
        return 3
    if not isinstance(cfg, dict):
        sys.stderr.write("extract-routing: config response is not a JSON object\n")
        return 3
    routing = cfg.get("routing")
    if routing is None:
        sys.stderr.write("extract-routing: warning: config has no 'routing' object\n")
    stream_out.write(dumps({"routing": routing}))
    return 0


def sanitize_dir(raw_dir, out_dir, secrets=()):
    docs = {}
    for name in sorted(os.listdir(raw_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(raw_dir, name)
        try:
            with open(path, encoding="utf-8") as f:
                docs[name] = json.load(f)
        except ValueError:
            sys.stderr.write("sanitize: %s is not valid JSON; nothing written\n" % name)
            return 3
    try:
        out = sanitize_documents(docs, secrets)
    except ValueError as e:
        sys.stderr.write("sanitize: %s\n" % e)
        return 3
    os.makedirs(out_dir, exist_ok=True)
    for name, doc in out.items():
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            f.write(dumps(doc))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "extract-routing":
        return extract_routing(sys.stdin, sys.stdout)
    if len(argv) == 4 and argv[1] == "sanitize":
        # Secrets come on stdin, one per line, never through argv or the environment.
        secrets = [] if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read().splitlines()
        return sanitize_dir(argv[2], argv[3], secrets)
    sys.stderr.write(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
