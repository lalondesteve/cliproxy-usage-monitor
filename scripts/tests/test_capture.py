"""Tests for scripts/capture-fixtures.sh and scripts/sanitize_fixtures.py (task T2).

Run from the repo root:  python3 -m unittest discover -s scripts/tests
"""

import copy
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SCRIPTS)

import sanitize_fixtures  # noqa: E402

CAPTURE = os.path.join(SCRIPTS, "capture-fixtures.sh")

MGMT_KEY = "mgmt-secret-key-5f3a9c"
# A key with characters that need escaping in JSON, in curl's config syntax and in
# bash patterns.
ODD_KEY = 'odd-key"quote\\back*star?[x]-7c1d'


# Go's encoding/json escapes &, < and > as \u0026, \u003c and \u003e.
GO_KEY = "go-key&amp<lt>gt-3e9a"

# Every variable name the script uses to hold a secret or an Authorization header.
INTERNAL_SECRET_NAMES = ("cliproxy_key", "ocgo_token", "secret", "esc", "header", "value",
                         "t", "s", "e", "g", "body")


def json_escaped(secret):
    return json.dumps(secret)[1:-1]


def go_json(obj):
    return (json.dumps(obj).replace("&", "\\u0026").replace("<", "\\u003c")
            .replace(">", "\\u003e"))


OCGO_TOKEN = "ocgo-client-token-81bd27"
OPAQUE = "sk-test-opaque-1234"
REAL_ACCOUNT_ID = "4c1e7a52-91d3-4b8e-a0f2-6d5e3c2b1a09"


def fake_jwt(tag):
    return "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiI%s.c2lnbmF0dXJl" % tag


ROUTING = {
    "strategy": "fill-first",
    "session-affinity": True,
    "session-affinity-ttl": "1h",
}

CREDENTIALS = {
    "files": [
        {
            "id": "claude-1a2b3c4d-alice@gmail.com.json",
            "name": "claude-1a2b3c4d-alice@gmail.com.json",
            "path": "/root/.cli-proxy-api/claude-1a2b3c4d-alice@gmail.com.json",
            "auth_index": "idx-alice",
            "provider": "claude",
            "email": "alice@gmail.com",
            "disabled": False,
            "unavailable": False,
            "status": "active",
            "success": 120,
            "failed": 2,
            "priority": 0,
            "access_token": fake_jwt("alice-access"),
            "refresh_token": "rt-alice-refresh-0001",
            "recent_requests": [{"time": "10:40", "success": 3, "failed": 0}],
            "quota": {
                "observed_at": "2026-11-22T10:41:00Z",
                "signals": {
                    "Anthropic-Ratelimit-Unified-5h-Utilization": "0.53",
                    "Anthropic-Ratelimit-Unified-7d-Utilization": "0.21",
                    "Anthropic-Ratelimit-Unified-5h-Reset": "1795430400",
                    "Anthropic-Ratelimit-Unified-7d-Reset": "1795862400",
                    "Anthropic-Ratelimit-Unified-Status": "allowed",
                },
            },
        },
        {
            # Second file of the same subscription (same org hash), other member.
            "id": "claude-1a2b3c4d-bob.smith@corp.example.co.uk.json",
            "name": "claude-1a2b3c4d-bob.smith@corp.example.co.uk.json",
            "auth_index": "idx-bob",
            "provider": "claude",
            "email": "Bob.Smith@corp.example.co.uk",
            "status": "active",
            "success": 7,
            "failed": 0,
            "access_token": fake_jwt("bob-access"),
            "refresh_token": fake_jwt("bob-refresh"),
            "quota": {"observed_at": "2026-11-22T09:00:00Z", "signals": {}},
        },
        {
            "id": "codex-carol@outlook.com-plus.json",
            "name": "codex-carol@outlook.com-plus.json",
            "auth_index": "idx-carol",
            "provider": "codex",
            "email": "carol@outlook.com",
            "status": "active",
            "success": 55,
            "failed": 1,
            "id_token": {
                "chatgpt_account_id": REAL_ACCOUNT_ID,
                "plan_type": "plus",
                "sub": "auth0|carol-subject",
                "raw": fake_jwt("carol-id"),
            },
            "api_key": "sk-proj-carol-apikey-777",
            "client_secret": "carol-client-secret-888",
            "quota": {
                "observed_at": "2026-11-22T10:30:00Z",
                "signals": {
                    "X-Codex-Primary-Used-Percent": ["42"],
                    "X-Codex-Primary-Window-Minutes": ["10080"],
                    "X-Codex-Primary-Reset-After-Seconds": ["86400"],
                    "X-Codex-Plan-Type": ["plus"],
                    "Chatgpt-Account-Id": [REAL_ACCOUNT_ID],
                    "Set-Cookie": ["session=abcdef"],
                },
            },
        },
        {
            "id": "codex-dave@proton.me-team.json",
            "auth_index": "idx-dave",
            "provider": "codex",
            "email": "dave@proton.me",
            "id_token": fake_jwt("dave-id"),
            "chatgpt_account_id": "dave-account-0042",
            "quota": {"signals": {"X-Codex-Secondary-Used-Percent": "10"}},
        },
    ]
}

# Same accounts, opposite order, as the fork's poller reports them.
QUOTA_HISTORY = {
    "accounts": [
        {
            "id": "codex-dave@proton.me-team.json",
            "auth_index": "idx-dave",
            "provider": "codex",
            "email": "dave@proton.me",
            "status": "ok",
            "reading": {"windows": [{"window": "weekly", "remaining": 90}]},
        },
        {
            "id": "codex-carol@outlook.com-plus.json",
            "auth_index": "idx-carol",
            "provider": "codex",
            "email": "carol@outlook.com",
            "chatgpt_account_id": REAL_ACCOUNT_ID,
            "status": "ok",
            "reading": {"windows": [{"window": "weekly", "remaining": 58}]},
        },
        {
            "id": "claude-1a2b3c4d-bob.smith@corp.example.co.uk.json",
            "auth_index": "idx-bob",
            "provider": "anthropic",
            "email": "bob.smith@corp.example.co.uk",
            "status": "ok",
            "reading": {"windows": [{"window": "short", "remaining": 47}]},
        },
        {
            "id": "claude-1a2b3c4d-alice@gmail.com.json",
            "auth_index": "idx-alice",
            "provider": "anthropic",
            "email": "alice@gmail.com",
            "status": "ok",
            "reading": {
                "windows": [
                    {"window": "short", "remaining": 47, "resetAt": "0001-01-01T00:00:00Z"}
                ]
            },
        },
    ],
    "pools": [
        {
            "provider": "anthropic",
            "window": "short",
            "history": [
                {
                    "at": "2026-11-22T10:00:00Z",
                    "accounts": [
                        {"id": "claude-1a2b3c4d-alice@gmail.com.json", "status": "ok",
                         "remaining": 47, "observedAt": "2026-11-22T09:58:00Z",
                         "resetAt": "2026-11-22T12:00:00Z"},
                    ],
                }
            ],
        }
    ],
}

CONFIG = {
    "host": "",
    "port": 8317,
    "api-keys": [OPAQUE],
    "remote-management": {"allow-remote": True, "secret-key": OPAQUE},
    "upstream-url": "https://upstream.internal.invalid/v1?key=" + OPAQUE,
    "debug": False,
    "routing": ROUTING,
}

ROUTING_STRATEGY = {"strategy": "fill-first"}

OCGO_STATUS = {
    "time": "2026-11-22T10:42:00Z",
    "accounts": [
        {
            "name": "team-a",
            "owner_email": "erin@opencode.example.net",
            "available": True,
            "headroom": 38,
            "exhausted": False,
            "polled_at": "2026-11-22T10:41:00Z",
            "poll_error": "",
            "windows": {
                "rolling": {"status": "ok", "percent": 62, "resets_at": "2026-11-22T12:00:00Z"},
                "weekly": {"status": "ok", "percent": 30, "resets_at": "2026-11-24T00:00:00Z"},
                "monthly": {"status": "ok", "percent": 12, "resets_at": "2026-12-01T00:00:00Z"},
            },
            "console_available": True,
            "free_available": True,
        }
    ],
}

PAYLOADS = {
    "/v8/management/credentials": CREDENTIALS,
    "/v8/management/quota/history?range=24h": QUOTA_HISTORY,
    "/v0/management/routing/strategy": ROUTING_STRATEGY,
    "/v0/management/config": CONFIG,
    "/_ocgo/status": OCGO_STATUS,
}


def raw_docs():
    """The documents the shell script hands to the sanitizer."""
    return {
        "cliproxy-credentials.json": copy.deepcopy(CREDENTIALS),
        "cliproxy-quota-history-24h.json": copy.deepcopy(QUOTA_HISTORY),
        "cliproxy-routing-strategy.json": copy.deepcopy(ROUTING_STRATEGY),
        "cliproxy-config-routing.json": {"routing": copy.deepcopy(CONFIG["routing"])},
        "ocgo-status.json": copy.deepcopy(OCGO_STATUS),
    }


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def read_all_text(directory):
    text = {}
    for root, _dirs, files in os.walk(directory):
        for f in files:
            with open(os.path.join(root, f), encoding="utf-8") as fh:
                text[os.path.join(root, f)] = fh.read()
    return text


class OutputAssertions:
    def assert_sanitized_dir(self, out_dir):
        texts = read_all_text(out_dir)
        self.assertTrue(texts, "no output files")
        for path, text in texts.items():
            for m in re.finditer(r"@([A-Za-z0-9.-]*)", text):
                self.assertTrue(
                    re.match(r"example\.com(?:\.json|-[a-z]+(?:\.json)?)?$", m.group(1)),
                    "%s has a non-example.com '@': %r" % (path, m.group(0)),
                )
            self.assertNotIn("eyJ", text, path)
            for secret in (OPAQUE, MGMT_KEY, OCGO_TOKEN, REAL_ACCOUNT_ID, "dave-account-0042",
                           "rt-alice-refresh", "sk-proj-carol", "carol-client-secret",
                           "upstream.internal", "session=abcdef", "auth0|carol"):
                self.assertNotIn(secret, text, path)
        # grep -r over the output dir finds the opaque key nowhere.
        grep = subprocess.run(["grep", "-r", OPAQUE, out_dir], capture_output=True)
        self.assertEqual(grep.returncode, 1, grep.stdout)

        creds = load(os.path.join(out_dir, "cliproxy-credentials.json"))["files"]
        hist = load(os.path.join(out_dir, "cliproxy-quota-history-24h.json"))
        routing = load(os.path.join(out_dir, "cliproxy-config-routing.json"))
        self.assertEqual(routing, {"routing": ROUTING})

        by_idx = {c["auth_index"]: c for c in creds}
        # Two files of one subscription keep the shared 8-hex hash.
        self.assertTrue(by_idx["idx-alice"]["id"].startswith("claude-1a2b3c4d-"))
        self.assertTrue(by_idx["idx-bob"]["id"].startswith("claude-1a2b3c4d-"))
        self.assertNotEqual(by_idx["idx-alice"]["email"], by_idx["idx-bob"]["email"])
        for c in creds:
            self.assertRegex(c["email"], r"^user-\d+@example\.com$")
            self.assertIn(c["email"], c["id"])
            for gone in ("access_token", "refresh_token", "api_key", "client_secret"):
                self.assertNotIn(gone, c)
        # Credential name shapes survive around the replaced email.
        self.assertRegex(by_idx["idx-alice"]["id"], r"^claude-1a2b3c4d-user-\d+@example\.com\.json$")
        self.assertRegex(by_idx["idx-carol"]["id"], r"^codex-user-\d+@example\.com-plus\.json$")

        # Joins across files: opposite order, same sanitized ids and emails.
        for h in hist["accounts"]:
            c = by_idx[h["auth_index"]]
            self.assertEqual(h["id"], c["id"])
            self.assertEqual(h["email"], c["email"])
        self.assertEqual(hist["pools"][0]["history"][0]["accounts"][0]["id"], by_idx["idx-alice"]["id"])

        # id_token object keeps only the faked account id and the plan type.
        carol_tok = by_idx["idx-carol"]["id_token"]
        self.assertEqual(set(carol_tok), {"chatgpt_account_id", "plan_type"})
        fake = carol_tok["chatgpt_account_id"]
        self.assertRegex(fake, r"^00000000-0000-4000-8000-\d{12}$")
        carol_hist = [h for h in hist["accounts"] if h["auth_index"] == "idx-carol"][0]
        self.assertEqual(carol_hist["chatgpt_account_id"], fake)
        signals = by_idx["idx-carol"]["quota"]["signals"]
        self.assertEqual(signals["Chatgpt-Account-Id"], [fake])
        # An id_token string (a JWT) is dropped; a top-level account id is faked.
        self.assertNotIn("id_token", by_idx["idx-dave"])
        self.assertRegex(by_idx["idx-dave"]["chatgpt_account_id"], r"^00000000-")
        self.assertNotEqual(by_idx["idx-dave"]["chatgpt_account_id"], fake)

        # Header names and casing are kept; Set-Cookie is dropped.
        self.assertEqual(
            list(signals),
            ["X-Codex-Primary-Used-Percent", "X-Codex-Primary-Window-Minutes",
             "X-Codex-Primary-Reset-After-Seconds", "X-Codex-Plan-Type", "Chatgpt-Account-Id"],
        )
        self.assertEqual(
            list(by_idx["idx-alice"]["quota"]["signals"]),
            list(CREDENTIALS["files"][0]["quota"]["signals"]),
        )
        self.assertEqual(by_idx["idx-alice"]["quota"]["signals"]["Anthropic-Ratelimit-Unified-5h-Utilization"], "0.53")

        ocgo = load(os.path.join(out_dir, "ocgo-status.json"))
        self.assertEqual(ocgo["accounts"][0]["windows"], OCGO_STATUS["accounts"][0]["windows"])
        self.assertRegex(ocgo["accounts"][0]["owner_email"], r"^user-\d+@example\.com$")


class SanitizerTests(unittest.TestCase, OutputAssertions):
    def test_sanitize_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw, out = os.path.join(tmp, "raw"), os.path.join(tmp, "out")
            os.mkdir(raw)
            for name, doc in raw_docs().items():
                with open(os.path.join(raw, name), "w") as f:
                    json.dump(doc, f)
            self.assertEqual(sanitize_fixtures.sanitize_dir(raw, out), 0)
            self.assert_sanitized_dir(out)

    def test_email_numbering_does_not_depend_on_order(self):
        a = sanitize_fixtures.sanitize_documents(raw_docs())
        reversed_docs = raw_docs()
        reversed_docs["cliproxy-credentials.json"]["files"].reverse()
        b = sanitize_fixtures.sanitize_documents(reversed_docs)
        emails = lambda d: sorted(x["email"] for x in d["cliproxy-credentials.json"]["files"])  # noqa: E731
        self.assertEqual(emails(a), emails(b))
        self.assertEqual(a["cliproxy-quota-history-24h.json"], b["cliproxy-quota-history-24h.json"])

    def test_extract_routing_drops_everything_else(self):
        import io
        out = io.StringIO()
        self.assertEqual(sanitize_fixtures.extract_routing(io.StringIO(json.dumps(CONFIG)), out), 0)
        self.assertEqual(json.loads(out.getvalue()), {"routing": ROUTING})
        self.assertNotIn(OPAQUE, out.getvalue())

    def test_account_id_only_in_header_list_is_faked(self):
        # Go http.Header shape: the id appears only as a string-array header value,
        # and the JWT id_token that carried it is dropped.
        real = "9b2f6c1e-3d4a-4e5f-8a7b-1c2d3e4f5a6b"
        cred = {"files": [{
            "id": "codex-zed@mail.example.net-pro.json", "provider": "codex",
            "email": "zed@mail.example.net", "id_token": fake_jwt("zed-id"),
            "quota": {"signals": {"Chatgpt-Account-Id": [real],
                                  "X-Codex-Primary-Window-Minutes": ["300"]}},
        }]}
        other = {"accounts": [{"id": "codex-zed@mail.example.net-pro.json",
                               "headers": {"Chatgpt-Account-Id": [real]}}]}
        out = sanitize_fixtures.sanitize_documents({"a.json": cred, "b.json": other})
        text = json.dumps(out)
        self.assertNotIn(real, text)
        entry = out["a.json"]["files"][0]
        self.assertNotIn("id_token", entry)
        fake = entry["quota"]["signals"]["Chatgpt-Account-Id"]
        self.assertEqual(len(fake), 1)
        self.assertRegex(fake[0], r"^00000000-0000-4000-8000-\d{12}$")
        self.assertEqual(out["b.json"]["accounts"][0]["headers"]["Chatgpt-Account-Id"], fake)

    def test_file_name_email_is_not_matched_to_a_shorter_address(self):
        # No standalone email for jane; another account's email is a suffix of hers.
        docs = {"c.json": {"files": [
            {"id": "claude-1a2b3c4d-jane-doe@gmail.com.json", "provider": "claude"},
            {"id": "claude-9f8e7d6c-doe@gmail.com.json", "provider": "claude",
             "email": "doe@gmail.com"},
        ]}}
        files = sanitize_fixtures.sanitize_documents(docs)["c.json"]["files"]
        jane, doe = files[0]["id"], files[1]
        self.assertRegex(jane, r"^claude-1a2b3c4d-user-\d+@example\.com\.json$")
        self.assertNotIn("jane", jane)
        self.assertNotIn(doe["email"], jane)
        self.assertEqual(doe["id"], "claude-9f8e7d6c-%s.json" % doe["email"])

    def test_secret_check_sees_decoded_strings(self):
        # The raw JSON text holds the key escaped (odd-key\"quote\\back...), so a
        # byte search for the key would miss it; the decoded check must not.
        doc = {"poll_error": "rejected key " + ODD_KEY}
        self.assertNotIn(ODD_KEY, json.dumps(doc))
        with self.assertRaises(ValueError):
            sanitize_fixtures.sanitize_documents({"x.json": doc}, secrets=[ODD_KEY])
        with self.assertRaises(ValueError):
            sanitize_fixtures.sanitize_documents({"x.json": {ODD_KEY: 1}}, secrets=[ODD_KEY])
        sanitize_fixtures.sanitize_documents({"x.json": {"ok": 1}}, secrets=[ODD_KEY])

    def test_leak_check_refuses_unknown_at(self):
        with self.assertRaises(ValueError):
            sanitize_fixtures.sanitize_documents({"x.json": {"note": "ping me at someone@"}})


class StubHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        server = self.server
        server.requests.append({"path": self.path, "headers": dict(self.headers.items())})
        status, payload = server.respond(self.path)
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class StubServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls socket.getfqdn, a reverse DNS lookup that can
        # take tens of seconds; the stub doesn't need a server name.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class RawStub:
    """Answers every request with exact bytes, e.g. a CRLF status line with no
    reason phrase, which http.server can't produce."""

    def __init__(self, response):
        requests = self.requests = []

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                lines = []
                while True:
                    line = self.rfile.readline()
                    if not line or line in (b"\r\n", b"\n"):
                        break
                    lines.append(line.decode("latin-1").rstrip("\r\n"))
                requests.append(lines)
                self.wfile.write(response)

        socketserver.ThreadingTCPServer.allow_reuse_address = True
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()


class Stub:
    def __init__(self, respond):
        self.httpd = StubServer(("127.0.0.1", 0), StubHandler)
        self.httpd.requests = []
        self.httpd.respond = respond
        self.url = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def requests(self):
        return self.httpd.requests

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


WRAPPED_COMMANDS = ("curl", "python3", "dirname", "mktemp", "date", "awk", "head", "tr",
                    "grep", "cp", "rm", "chmod", "mkdir", "ls", "wc", "cat", "sed")


def serve_payloads(path):
    if path in PAYLOADS:
        return 200, PAYLOADS[path]
    return 404, {"error": "not found"}


class CaptureScriptTests(unittest.TestCase, OutputAssertions):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.out = os.path.join(self.tmp, "out")
        self.tmpdir = os.path.join(self.tmp, "tmpdir")
        os.mkdir(self.tmpdir)
        # Wrappers for every external command the script might run. Each logs its
        # argv and environment, so the test can check that no child process ever
        # sees a secret either way.
        self.log = os.path.join(self.tmp, "exec.log")
        bindir = os.path.join(self.tmp, "bin")
        os.mkdir(bindir)
        for cmd in WRAPPED_COMMANDS:
            real = shutil.which(cmd)
            if real is None:
                continue
            with open(os.path.join(bindir, cmd), "w") as f:
                f.write('#!/bin/sh\n{ printf "EXEC:%%s\\n" "$0"; printf "ARGV:%%s\\n" "$@"; '
                        '/usr/bin/env; } >> "%s"\nexec "%s" "$@"\n' % (self.log, real))
            os.chmod(os.path.join(bindir, cmd), 0o755)
        self.path = bindir + os.pathsep + os.environ.get("PATH", "")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_capture(self, cliproxy_url, ocgo_url, key=MGMT_KEY, token=OCGO_TOKEN, extra_env=None):
        env = {
            "PATH": self.path,
            "HOME": self.tmp,
            "TMPDIR": self.tmpdir,
            "CLIPROXY_URL": cliproxy_url,
            "OCGO_URL": ocgo_url,
            "OUT_DIR": self.out,
            "CLIPROXY_MANAGEMENT_KEY": key,
            "OCGO_TOKEN": token,
            "CAPTURE_TIMEOUT": "10",
        }
        env.update(extra_env or {})
        return subprocess.run(["bash", CAPTURE], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=120)

    def assert_no_secret_leaked(self, proc, secrets=(MGMT_KEY, OCGO_TOKEN)):
        log = read_text(self.log) if os.path.exists(self.log) else ""
        for secret in secrets:
            forms = {secret, json_escaped(secret), go_json(secret)[1:-1]}
            for form in forms:
                self.assertFalse(form in proc.stdout, "secret on stdout")
                self.assertFalse(form in proc.stderr, "secret on stderr")
            self.assertFalse(secret in log, "secret in a child process's argv or env")
        self.assertEqual(os.listdir(self.tmpdir), [], "temp dir left behind")

    def test_end_to_end_against_stub(self):
        with Stub(serve_payloads) as cliproxy, Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            [r["path"] for r in cliproxy.requests],
            ["/v8/management/credentials", "/v8/management/quota/history?range=24h",
             "/v0/management/routing/strategy", "/v0/management/config"],
        )
        self.assertEqual([r["path"] for r in ocgo.requests], ["/_ocgo/status"])
        for r in cliproxy.requests:
            self.assertEqual(r["headers"].get("Authorization"), "Bearer " + MGMT_KEY)
        self.assertEqual(ocgo.requests[0]["headers"].get("Authorization"), "Bearer " + OCGO_TOKEN)
        self.assertEqual(
            sorted(os.listdir(self.out)),
            sorted(["cliproxy-credentials.json", "cliproxy-quota-history-24h.json",
                    "cliproxy-routing-strategy.json", "cliproxy-config-routing.json",
                    "ocgo-status.json", "capture-manifest.json"]),
        )
        self.assert_sanitized_dir(self.out)
        manifest = load(os.path.join(self.out, "capture-manifest.json"))
        self.assertEqual([e["status"] for e in manifest["endpoints"]], [200] * 5)
        self.assert_no_secret_leaked(proc)

    def test_401_stops_after_one_request(self):
        with Stub(lambda p: (401, {"error": "invalid management key"})) as cliproxy, \
                Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("401", proc.stderr)
        self.assertIn("STOPPED", proc.stderr)
        self.assertEqual(len(cliproxy.requests), 1)
        self.assertEqual(len(ocgo.requests), 0)
        self.assertEqual(cliproxy.requests[0]["headers"].get("Authorization"), "Bearer " + MGMT_KEY)
        self.assertFalse(os.path.exists(self.out))
        self.assert_no_secret_leaked(proc)

    def test_403_midway_stops_both_proxies(self):
        def respond(path):
            if path.startswith("/v8/management/quota/history"):
                return 403, {"error": "remote management disabled"}
            return serve_payloads(path)

        with Stub(respond) as cliproxy, Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(len(cliproxy.requests), 2)
        self.assertEqual(len(ocgo.requests), 0)
        self.assertFalse(os.path.exists(self.out))
        self.assert_no_secret_leaked(proc)

    def test_ocgo_401_is_reported(self):
        with Stub(serve_payloads) as cliproxy, Stub(lambda p: (401, {})) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(len(ocgo.requests), 1)
        self.assertIn("ocgo-proxy", proc.stderr)
        self.assertFalse(os.path.exists(self.out))
        self.assert_no_secret_leaked(proc)

    def test_missing_quota_history_is_partial_not_fatal(self):
        def respond(path):
            if path.startswith("/v8/management/quota/history"):
                return 404, {"error": "not found"}
            return serve_payloads(path)

        with Stub(respond) as cliproxy, Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertEqual(len(cliproxy.requests), 4)
        self.assertEqual(len(ocgo.requests), 1)
        self.assertNotIn("cliproxy-quota-history-24h.json", os.listdir(self.out))
        manifest = load(os.path.join(self.out, "capture-manifest.json"))
        self.assertEqual([e["status"] for e in manifest["endpoints"]], [200, 404, 200, 200, 200])
        self.assert_no_secret_leaked(proc)

    def test_secret_as_argument_is_refused(self):
        for argv in ([MGMT_KEY], ["--ocgo-url", "http://127.0.0.1:1", MGMT_KEY]):
            proc = subprocess.run(["bash", CAPTURE] + argv, env={"PATH": self.path},
                                  capture_output=True, text=True, stdin=subprocess.DEVNULL)
            self.assertEqual(proc.returncode, 64)
            self.assertIn("unknown argument", proc.stderr)
            self.assertNotIn(MGMT_KEY, proc.stderr)
            self.assertNotIn(MGMT_KEY, proc.stdout)
        self.assertFalse(os.path.exists(self.log), "a child process ran")

    def test_child_processes_never_see_secrets(self):
        # The caller has exported the script's internal variable names; bash would
        # keep their export flag on assignment unless the script clears it.
        preexported = {name: "dummy-" + name for name in INTERNAL_SECRET_NAMES}
        with Stub(serve_payloads) as cliproxy, Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url, key=ODD_KEY, extra_env=preexported)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(cliproxy.requests[0]["headers"].get("Authorization"), "Bearer " + ODD_KEY)
        log = read_text(self.log)
        for cmd in ("curl", "python3"):
            self.assertIn("/%s\n" % cmd, log, "%s wrapper not exercised" % cmd)
        self.assertNotIn("CLIPROXY_MANAGEMENT_KEY", log)
        self.assertNotIn("OCGO_TOKEN", log)
        self.assert_no_secret_leaked(proc, secrets=(ODD_KEY, OCGO_TOKEN))

    def test_crlf_status_line_without_reason_stops(self):
        for status in (b"401", b"403"):
            with self.subTest(status=status):
                response = (b"HTTP/1.1 " + status + b"\r\nContent-Type: text/plain\r\n"
                            b"Content-Length: 0\r\nConnection: close\r\n\r\n")
                with RawStub(response) as cliproxy, Stub(serve_payloads) as ocgo:
                    proc = self.run_capture(cliproxy.url, ocgo.url)
                self.assertEqual(proc.returncode, 2, proc.stderr)
                self.assertIn("STOPPED", proc.stderr)
                self.assertEqual(len(cliproxy.requests), 1)
                self.assertEqual(len(ocgo.requests), 0)
                self.assertFalse(os.path.exists(self.out))
                self.assert_no_secret_leaked(proc)

    def test_401_body_is_shown_with_both_secrets_masked(self):
        echo = {"error": "invalid management key " + ODD_KEY, "token": OCGO_TOKEN, "pad": ""}
        # Pad so a third copy of the key straddles the 300-character cut: masking
        # after cutting would print its first half.
        prefix = len(json.dumps(echo).rstrip('"}'))
        echo["pad"] = "x" * (285 - prefix) + ODD_KEY
        self.assertLess(json.dumps(echo).index(json_escaped(ODD_KEY), 100), 300)
        with Stub(lambda p: (401, echo)) as cliproxy, Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url, key=ODD_KEY)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(len(cliproxy.requests), 1)
        self.assertIn("Response body:", proc.stderr)
        self.assertIn("invalid management key <secret>", proc.stderr)
        self.assertIn('"token": "<secret>"', proc.stderr)
        self.assertNotIn("odd-key", proc.stderr)
        self.assert_no_secret_leaked(proc, secrets=(ODD_KEY, OCGO_TOKEN))

    def test_401_body_masks_go_escaped_secret(self):
        body = go_json({"error": "invalid management key " + GO_KEY})
        self.assertIn("go-key" + chr(92) + "u0026amp", body)
        with Stub(lambda p: (401, body.encode())) as cliproxy, Stub(serve_payloads) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url, key=GO_KEY)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(len(cliproxy.requests), 1)
        self.assertEqual(cliproxy.requests[0]["headers"].get("Authorization"), "Bearer " + GO_KEY)
        self.assertIn("invalid management key <secret>", proc.stderr)
        self.assertNotIn("go-key", proc.stderr)
        self.assert_no_secret_leaked(proc, secrets=(GO_KEY, OCGO_TOKEN))

    def test_escaped_secret_echo_in_200_body_blocks_writing(self):
        def respond(path):
            if path == "/_ocgo/status":
                status = copy.deepcopy(OCGO_STATUS)
                status["accounts"][0]["poll_error"] = "upstream rejected " + ODD_KEY
                return 200, status
            return serve_payloads(path)

        with Stub(respond) as cliproxy, Stub(respond) as ocgo:
            proc = self.run_capture(cliproxy.url, ocgo.url, key=ODD_KEY)
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("management key or ocgo token", proc.stderr)
        self.assertFalse(os.path.exists(self.out))
        self.assert_no_secret_leaked(proc, secrets=(ODD_KEY, OCGO_TOKEN))


if __name__ == "__main__":
    unittest.main()
