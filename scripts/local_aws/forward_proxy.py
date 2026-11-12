"""Plain-HTTP forward proxy for the local emulator test only.

Some AWS endpoints put the account ID in front of the hostname (S3 Control:
`123456789012.127.0.0.1:5055`), which no resolver answers. Terraform sends HTTP requests to
this proxy (HTTP_PROXY), and the proxy forwards every request to the emulator unchanged,
keeping the original Host header so the emulator still sees the account prefix.

  python3 forward_proxy.py <listen-port> <emulator-port>
"""

from __future__ import annotations

import http.client
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

EMULATOR_PORT = int(sys.argv[2])


class Forward(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:  # quiet
        pass

    def _forward(self) -> None:
        url = urlsplit(self.path)
        target = url.path + (f"?{url.query}" if url.query else "")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        conn = http.client.HTTPConnection("127.0.0.1", EMULATOR_PORT, timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() != "proxy-connection"}
        conn.request(self.command, target, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        conn.close()

    do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = do_PATCH = _forward


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Forward).serve_forever()
