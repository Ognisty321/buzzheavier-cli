#!/usr/bin/env python3
"""Tiny stand-in for the buzzheavier.com API, used by tests/run.sh.

Usage: mock_server.py <port-file> <log-file>

Binds to a free port on 127.0.0.1, writes the port number to <port-file> and
appends one tab-separated line per request to <log-file>:

    METHOD <TAB> raw-path <TAB> Authorization header <TAB> body length <TAB> detail

`detail` is the JSON body for API calls and `note=<decoded note>` for uploads.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

TOKEN = "testtoken123"
PORT_FILE, LOG_FILE = sys.argv[1], sys.argv[2]

LISTING = {
    "code": 200,
    "data": {
        "id": "root0000root",
        "name": "Root",
        "isDirectory": True,
        "children": [
            {"id": "file00000001", "name": "zeta.bin", "isDirectory": False, "size": 1536,
             "downloads": 7, "createdAt": "2025-12-31T15:51:10.553152Z", "note": ""},
            {"id": "dir000000001", "name": "Movies", "isDirectory": True},
            {"id": "file00000002", "name": "alpha zażółć.txt", "isDirectory": False, "size": 12},
            {"id": "file00000003", "name": "big.iso", "isDirectory": False, "size": 5368709120},
        ],
    },
}
EMPTY_LISTING = {
    "code": 200,
    "data": {"id": "empty0000000", "name": "Empty", "isDirectory": True, "children": []},
}
LOCATIONS = {
    "code": 200,
    "data": [
        {"id": "loc000000001", "name": "Western Europe"},
        {"id": "loc000000002", "name": "Eastern US"},
    ],
}
ACCOUNT = {
    "code": 200,
    "data": {"id": "acc000000001", "email": "user@example.test", "plan": "free", "settings": {"x": 1}},
}

uploads = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output clean
        pass

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, body, detail):
        line = "\t".join(
            [self.command, self.path, self.headers.get("Authorization", "-"), str(len(body)), detail]
        )
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    def _authorized(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def _handle(self):
        global uploads
        body = self._body()
        url = urlsplit(self.path)
        parts = [unquote(p) for p in url.path.split("/") if p]

        # ---- uploads: PUT /<name> or PUT /<parentId>/<name>
        if self.command == "PUT" and (not parts or parts[0] != "api"):
            query = parse_qs(url.query)
            note = ""
            if "note" in query:
                note = base64.b64decode(query["note"][0]).decode("utf-8")
            self._record(body, "note=" + note)
            if len(parts) == 2 and not self._authorized():
                return self._send(401, {"code": 401, "error": "Unauthorized"})
            if len(parts) not in (1, 2):
                return self._send(400, {"code": 400, "error": "Bad Request"})
            if "#" in parts[-1]:  # the real server rejects such names as well
                return self._send(400, {"code": 400, "error": "the Name field is invalid"})
            uploads += 1
            return self._send(201, {"code": 201, "data": {"id": "up%010d" % uploads}})

        # ---- API
        self._record(body, body.decode("utf-8", "replace"))
        if parts[:2] == ["api", "locations"] and self.command == "GET":
            return self._send(200, LOCATIONS)
        if not self._authorized():
            return self._send(401, {"code": 401, "error": "Unauthorized"})
        if parts[:2] == ["api", "account"] and self.command == "GET":
            return self._send(200, ACCOUNT)
        if parts[:2] == ["api", "fs"]:
            target = parts[2] if len(parts) > 2 else ""
            if target == "missing":
                return self._send(404, {"code": 404, "error": "Not Found"})
            if self.command == "GET":
                return self._send(200, EMPTY_LISTING if target == "empty0000000" else LISTING)
            if self.command == "POST":
                name = json.loads(body)["name"]
                return self._send(201, {"code": 201, "data": {"id": "newdir000001", "name": name}})
            if self.command == "PATCH":
                json.loads(body)
                return self._send(200, {"code": 200, "data": None})
            if self.command == "PUT":  # documented for move/note, but the real server refuses it
                return self._send(405, {"code": 405, "error": "Method Not Allowed"})
            if self.command == "DELETE":
                return self._send(200, {"code": 200})
        return self._send(404, {"code": 404, "error": "Not Found"})

    do_GET = do_PUT = do_POST = do_PATCH = do_DELETE = _handle


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
