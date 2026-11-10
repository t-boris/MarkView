#!/usr/bin/env python3
"""Approval Desk: a tiny two-user web app that End-to-End QA checks run against (feature end-to-end-qa).

Alice files expense requests, Bob approves or rejects them, and each sees the other's action. State lives in memory, so every
start (or POST /api/reset) gives the same baseline. The users and passwords below are test data only.

    python3 Tests/Fixtures/qa-demo/server.py --port 8765

DEMO_BUG=1 makes an approved request show as "Rejected" to its requester, so a check has a real defect to find.
"""
import argparse
import json
import os
import secrets
import threading
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

USERS = {
    "alice": {"password": "alice-test-pass", "role": "requester", "iban": "DE89 3704 0044 0532 0130 00"},
    "bob": {"password": "bob-test-pass", "role": "approver", "iban": "FR14 2004 1010 0505 0001 3M02 606"},
}
LOCK = threading.Lock()
STATE = {"sessions": {}, "requests": [], "next": 1}
HERE = Path(__file__).parent
BUG = os.environ.get("DEMO_BUG") == "1"


def reset():
    STATE["sessions"].clear()
    STATE["requests"].clear()
    STATE["next"] = 1


def visible(request, user):
    return USERS[user]["role"] == "approver" or request["owner"] == user


def shown(request, user):
    item = dict(request)
    if BUG and USERS[user]["role"] == "requester" and item["status"] == "approved":
        item["status"] = "rejected"
    return item


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def user(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        token = cookie["session"].value if "session" in cookie else ""
        return STATE["sessions"].get(token)

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            data = (HERE / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        with LOCK:
            user = self.user()
            if self.path == "/api/me":
                if not user:
                    return self.send_json(401, {"error": "Not signed in"})
                return self.send_json(200, {"user": user, "role": USERS[user]["role"], "iban": USERS[user]["iban"]})
            if self.path == "/api/requests":
                if not user:
                    return self.send_json(401, {"error": "Not signed in"})
                return self.send_json(200, [shown(r, user) for r in STATE["requests"] if visible(r, user)])
        self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        payload = self.body()
        with LOCK:
            if self.path == "/api/reset":
                reset()
                return self.send_json(200, {"ok": True})
            if self.path == "/api/login":
                name = str(payload.get("user", "")).lower()
                if name not in USERS or USERS[name]["password"] != payload.get("password"):
                    return self.send_json(401, {"error": "Wrong user name or password"})
                token = secrets.token_hex(16)
                STATE["sessions"][token] = name
                return self.send_json(200, {"user": name}, {"Set-Cookie": f"session={token}; Path=/; HttpOnly; SameSite=Lax"})
            user = self.user()
            if not user:
                return self.send_json(401, {"error": "Not signed in"})
            if self.path == "/api/requests" and USERS[user]["role"] == "requester":
                title = str(payload.get("title", "")).strip()
                try:
                    amount = float(payload.get("amount"))
                except (TypeError, ValueError):
                    amount = -1
                if not title or amount <= 0:
                    return self.send_json(400, {"error": "A title and a positive amount are required"})
                request = {"id": STATE["next"], "owner": user, "title": title, "amount": amount, "status": "pending", "note": ""}
                STATE["next"] += 1
                STATE["requests"].append(request)
                return self.send_json(201, request)
            parts = self.path.strip("/").split("/")
            if len(parts) == 4 and parts[:2] == ["api", "requests"] and parts[3] == "decision" and USERS[user]["role"] == "approver":
                match = [r for r in STATE["requests"] if str(r["id"]) == parts[2]]
                decision = payload.get("decision")
                if not match or decision not in ("approve", "reject"):
                    return self.send_json(400, {"error": "Unknown request or decision"})
                match[0]["status"] = "approved" if decision == "approve" else "rejected"
                match[0]["note"] = str(payload.get("note", ""))
                return self.send_json(200, match[0])
        self.send_json(403, {"error": "Not allowed"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Approval Desk on http://127.0.0.1:{args.port}/ (DEMO_BUG={'1' if BUG else '0'})", flush=True)
    server.serve_forever()
