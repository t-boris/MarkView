#!/usr/bin/env python3
"""An isolated, always-offline loopback relay for saved-connection tests."""
import http.server
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
temporary = pathlib.Path('/tmp').resolve()
if root.parent != temporary or not root.name.startswith('mvsaved-test-'):
    raise SystemExit('refusing a non-test fixture directory')


class Offline(http.server.BaseHTTPRequestHandler):
    def reject(self):
        self.send_response(503)
        self.send_header('Content-Length', '0')
        self.send_header('Connection', 'close')
        self.end_headers()

    do_GET = reject
    do_POST = reject
    do_PUT = reject
    do_DELETE = reject

    def log_message(self, format, *args):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Offline)
server.daemon_threads = True
port_file = root / 'relay.port'
with port_file.open('x', encoding='ascii') as output:
    os.chmod(port_file, 0o600)
    output.write(str(server.server_port))
server.serve_forever()
