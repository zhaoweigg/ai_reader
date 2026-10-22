#!/usr/bin/env python3
"""Serve the shared simulator registry as a read-only, loopback-only dashboard."""
import argparse
import json
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class DashboardHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, registry, **kwargs):
        self.registry = registry
        super().__init__(*args, **kwargs)

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path == '/':
            content = Path(__file__).with_name('coordination_dashboard.html').read_bytes()
            self.respond(200, content, 'text/html; charset=utf-8')
        elif path == '/api/status':
            try:
                state = json.loads(self.registry.read_text())
                if not isinstance(state, dict):
                    raise ValueError('Expected registry object')
                # Publish only operational slot/queue fields, never phone artifacts or credentials.
                status = {key: state.get(key, default) for key, default in
                          [('updated_at', None), ('slots', {}), ('slot_requests', []), ('agents', {})]}
                self.respond(200, json.dumps(status).encode(), 'application/json')
            except (OSError, ValueError, TypeError):
                self.respond(503, b'{"error":"Registry temporarily unavailable"}', 'application/json')
        elif path == '/favicon.ico':
            self.respond(204, b'', 'image/x-icon')
        else:
            self.respond(404, b'Not found', 'text/plain')

    def respond(self, code, content, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registry', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(DashboardHandler, registry=args.registry))
    print(f'http://127.0.0.1:{server.server_port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
