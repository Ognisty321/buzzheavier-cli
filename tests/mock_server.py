#!/usr/bin/env python3
"""Tiny stand-in for the buzzheavier.com API, used by tests/run.sh.

Usage: mock_server.py <port-file> <log-file>

Binds to a free port on 127.0.0.1, writes the port number to <port-file> and
appends one tab-separated line per request to <log-file>:

    METHOD <TAB> raw-path <TAB> Authorization header <TAB> body length <TAB> detail

`detail` is the JSON body for API calls, `note=<decoded note>` for uploads,
`range=<Range header>` for file downloads and `hx=<HX-Request header>` for pages.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit

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

# ---- downloads: file pages, the htmx "download" link and the file itself
DL_TOKEN = "tok123.abc"
DL_SECRET = "secret"
DL_CONTENT = bytes((i * 7 + 3) % 251 for i in range(5000))
DL_PAGES = {
    # id: (file name, token placed in the page)
    "dlfile000001": ("it's a zażółć & co.txt", DL_TOKEN),
    "dlfile000002": ("../evil.txt", DL_TOKEN),
    "badtoken0000": ("stale.txt", "expired"),
    "brokenfile00": ("broken.bin", DL_TOKEN),
}

uploads = 0


def html_escape(text):
    for raw, entity in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("'", "&#39;"), ('"', "&#34;")):
        text = text.replace(raw, entity)
    return text


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

    def _send_raw(self, status, data=b"", content_type="text/html; charset=utf-8", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _download(self, url, parts):
        """Everything a download touches: /<id>, /<id>/download and /d/<id>."""
        query = parse_qs(url.query)
        origin = "http://" + self.headers.get("Host", "")

        # the file itself
        if len(parts) == 2 and parts[0] == "d":
            self._record(b"", "range=" + self.headers.get("Range", "-"))
            if query.get("v") != [DL_SECRET]:
                return self._send_raw(403, b"Forbidden")
            if parts[1] == "brokenfile00":
                return self._send_raw(500, b"Internal Server Error")
            name = DL_PAGES[parts[1]][0]
            headers = [
                ("Accept-Ranges", "bytes"),
                ("Content-Disposition", "attachment; filename*=UTF-8''" + quote(name, safe="")),
            ]
            total = len(DL_CONTENT)
            rng = self.headers.get("Range")
            if rng:
                start = int(rng.split("=")[1].split("-")[0])
                if start >= total:
                    return self._send_raw(416, headers=[("Content-Range", "bytes */%d" % total)])
                headers.append(("Content-Range", "bytes %d-%d/%d" % (start, total - 1, total)))
                return self._send_raw(206, DL_CONTENT[start:], "application/octet-stream", headers)
            return self._send_raw(200, DL_CONTENT, "application/octet-stream", headers)

        self._record(b"", "hx=" + self.headers.get("HX-Request", "-"))
        file_id = parts[0] if parts else ""

        # the htmx link: answers with an HX-Redirect header instead of a body
        if len(parts) == 2 and parts[1] == "download" and file_id in DL_PAGES:
            if self.headers.get("HX-Request") != "true":
                return self._send_raw(403, b"Forbidden")
            target = origin + "/" + file_id  # no valid token: back to the page
            if query.get("t") == [DL_TOKEN]:
                target = "%s/d/%s?v=%s" % (origin, file_id, DL_SECRET)
                if query.get("alt") == ["true"]:
                    target += "&alt=1"
            return self._send_raw(204, headers=[("Hx-Redirect", target)])

        # the file page
        if len(parts) == 1 and file_id == "challenge000":
            return self._send_raw(403, b"<html><head><title>Just a moment...</title></head></html>")
        if len(parts) == 1 and file_id == "nolink000000":
            return self._send_raw(200, b"<html><head><title>A directory</title></head></html>")
        if len(parts) == 1 and file_id in DL_PAGES:
            name, token = DL_PAGES[file_id]
            link = "/%s/download?t=%s" % (file_id, token)
            page = (
                "<html><head><title>%s</title></head><body>\n"
                '<span class="size">4.9KB</span>\n'
                '<a hx-get="%s&amp;alt=true">Mirror 2</a>\n'
                '<a hx-get="%s">Download</a>\n'
                '<a hx-get="/%s/preview?t=%s">Preview</a>\n'
                "</body></html>\n"
            ) % (html_escape(name), link, link, file_id, token)
            return self._send_raw(200, page.encode("utf-8"))
        return self._send_raw(404, b"<html><head><title>Not Found</title></head></html>")

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

        # ---- downloads: any GET outside /api
        if self.command in ("GET", "HEAD") and (not parts or parts[0] != "api"):
            return self._download(url, parts)

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

    do_GET = do_HEAD = do_PUT = do_POST = do_PATCH = do_DELETE = _handle


class QuietServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # a client hanging up early (curl --fail does) is not worth a traceback


server = QuietServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
