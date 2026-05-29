#!/usr/bin/env python3
"""
Minimal local server for the Monitoring Settings Editor.
Serves monitoring_editor.html and exposes two API routes:
  GET  /api/settings  — reads  monitoring_settings.json
  POST /api/settings  — writes monitoring_settings.json
"""
import json
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

BASE = Path(__file__).parent.resolve()
JSON_FILE = BASE / "monitoring_settings.json"
HTML_FILE = BASE / "monitoring_editor.html"
PORT = 5757


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silence request logs in the console

    # ── GET ──────────────────────────────────────────────────────────────────
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(HTML_FILE.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/settings":
            self._send(JSON_FILE.read_bytes(), "application/json")
        else:
            self.send_error(404)

    # ── POST ─────────────────────────────────────────────────────────────────
    def do_POST(self):
        if self.path == "/api/settings":
            body = self.rfile.read(int(self.headers["Content-Length"]))
            data = json.loads(body)                       # validate JSON first
            JSON_FILE.write_text(
                json.dumps(data, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            self._send(b'{"ok":true}', "application/json")
        else:
            self.send_error(404)

    # ── helper ───────────────────────────────────────────────────────────────
    def _send(self, body: bytes, ctype: str):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    url = f"http://localhost:{PORT}"
    print(f"\n  Monitoring Settings Editor")
    print(f"  Open: {url}")
    print("  Stop: Ctrl+C\n")
    webbrowser.open(url)
    HTTPServer(("localhost", PORT), Handler).serve_forever()
