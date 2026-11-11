#!/usr/bin/env python3
"""Isolated loopback API fixture. No external services, credentials or persistence."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

items = {}
next_id = 1
writes = 0
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else b''
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def dispatch(self):
        global next_id, writes
        path = urlsplit(self.path).path
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            return self.reply(400, {'error': 'invalid JSON'})
        requests.append((self.command, path))
        if path == '/stats':
            return self.reply(200, {'requests': requests, 'writes': writes})
        if path == '/write-once':
            writes += 1
            return self.reply(201, {'writes': writes})
        if path == '/slow':
            time.sleep(4)
            return self.reply(200, {'ok': True})
        if path == '/large':
            return self.reply(200, {'value': 'x' * (3 * 1024 * 1024)})
        if path == '/redirect':
            return self.reply(302, {}, {'Location': 'http://127.0.0.1:1/leak'})
        if path == '/login' and self.command == 'POST':
            if body != {'username': 'alice', 'password': 'fixture-secret'}:
                return self.reply(401, {'error': 'invalid credentials'})
            return self.reply(200, {'token': 'fixture-bearer', 'password': body['password']},
                              {'Set-Cookie': 'session=alice; Path=/; HttpOnly'})
        if path == '/session':
            return self.reply(200 if self.headers.get('Cookie') == 'session=alice' else 401,
                              {'signedIn': self.headers.get('Cookie') == 'session=alice'})
        if path == '/echo':
            return self.reply(200, body)
        if path == '/types':
            return self.reply(200, {'boolean': True, 'number': 1, 'null': None, 'a/b': {'~key': [3]}})
        if path.startswith('/items'):
            if self.headers.get('Authorization') != 'Bearer fixture-bearer':
                return self.reply(401, {'error': 'unauthorized'})
            if path == '/items' and self.command == 'POST':
                if not isinstance(body.get('name'), str) or not body['name']:
                    return self.reply(422, {'error': 'name is required'})
                item = dict(id=next_id, name=body['name'])
                items[str(next_id)] = item
                next_id += 1
                return self.reply(201, item)
            key = path.removeprefix('/items/')
            if key not in items:
                return self.reply(404, {'error': 'not found'})
            if self.command == 'PATCH':
                items[key]['name'] = body['name']
            if self.command == 'DELETE':
                del items[key]
                return self.reply(204)
            return self.reply(200, items[key])
        self.reply(404, {'error': 'not found'})

    do_GET = do_POST = do_PATCH = do_DELETE = dispatch


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as file:
    file.write(str(server.server_port))
server.serve_forever()
