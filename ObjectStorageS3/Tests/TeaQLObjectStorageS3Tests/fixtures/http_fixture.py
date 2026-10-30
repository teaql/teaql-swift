"""Loopback error fixture. Prints only its port; no keys, request bodies or credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit
import time

class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        path = unquote(urlsplit(self.path).path).rstrip("/")
        status = 200 if path == "/bucket" else int(path.rsplit("/", 1)[-1].split("-", 2)[1])
        if status == 0:
            time.sleep(0.3)
            status = 503
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def do_PUT(self):
        self.send_response(501)
        self.end_headers()
    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
