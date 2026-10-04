"""Synthetic loopback-only fixture. Never reads real chat history or model files."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


EXPECTED = [
    {"role": "system", "content": "Synthetic test instruction."},
    {"role": "user", "content": "Remember 17."},
    {"role": "assistant", "content": "Stored 17."},
    {"role": "user", "content": "What value?"},
]


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 65536:
                self.send_error(400)
                return
            body = json.loads(self.rfile.read(size))
            valid = (
                self.path == "/v1/chat/completions"
                and self.headers.get("Authorization") == "Bearer synthetic-key"
                and body.get("messages") == EXPECTED
                and body.get("stream") is True
            )
            if not valid:
                self.send_response(400)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            mode = body["model"].removeprefix("fixture-")
            if mode == "http-error":
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if mode == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/v1/chat/completions")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            if mode == "sse-error":
                self.event({"error": {"message": "Synthetic server failure."}})
            elif mode == "malformed":
                self.wfile.write(b"data: not-json\n\n")
                self.wfile.flush()
            elif mode in ("unfinished", "length", "cancel"):
                self.event({"choices": [{"delta": {"content": "partial"}, "finish_reason": None}]})
                if mode == "length":
                    self.event({"choices": [{"delta": {}, "finish_reason": "length"}]})
                    self.wfile.write(b"data: [DONE]\n\n")
                elif mode == "cancel":
                    time.sleep(2)
            elif mode == "good":
                self.event({"choices": [{"delta": {"reasoning_content": "Synthetic reasoning."}, "finish_reason": None}]})
                payload = json.dumps({"choices": [{"delta": {"content": "17日"}, "finish_reason": None}]}, ensure_ascii=False)
                for byte in ("data: " + payload + "\r\n\r\n").encode():
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                self.event({"choices": [{"delta": {}, "finish_reason": "stop"}]})
                self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            # Do not print request bodies, headers, or exception dumps.
            self.close_connection = True

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    print(server.server_port, flush=True)
    server.serve_forever()
