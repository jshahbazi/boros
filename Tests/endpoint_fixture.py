"""Synthetic loopback-only fixture. Never reads real chat history or model files."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time
from pathlib import Path
from urllib.parse import urlsplit

MODEL = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
TEMPLATE = Path(__file__).with_name("qwen38-chat-template.jinja").read_text()
MODES = ["good", "http-error", "sse-error", "unfinished", "length", "redirect", "malformed", "cancel", "usage-missing", "usage-mismatch", "stream-model-mismatch"]
ADMISSION_MODES = ["template-mismatch", "version-mismatch", "model-mismatch", "count-mismatch", "bad-tokenizer", "admission-redirect", "admission-cancel"]
LOW = "Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration."


def render(body):
    messages = [m for m in body["messages"] if m["content"] != ""]
    system = messages[0]["content"].strip(" \t\r\n\v\f") if messages[0]["role"] == "system" else ""
    instruction = LOW if body["enable_thinking"] else ""
    text = ""
    if system or instruction:
        text += "<|im_start|>system\n" + instruction + ("\n\n" if instruction and system else "") + system + "<|im_end|>\n"
    for message in messages:
        role, content = message["role"], message["content"].strip(" \t\r\n\v\f")
        if role == "system":
            continue
        text += "<|im_start|>" + role + "\n"
        if role == "assistant":
            text += "<think>\n\n</think>\n\n"
        text += content + "<|im_end|>\n"
    text += "<|im_start|>assistant\n" + ("<think>\n" if body["enable_thinking"] else "<think>\n\n</think>\n\n")
    while "</think></think>" in text:
        text = text.replace("</think></think>", "</think>")
    return text


def count(text):
    # The fixture has a synthetic vocabulary: one token for every UTF-8 byte.
    # Production correctness is separately checked against the running server's own tokenizer.
    return len(text.encode())


EXPECTED = [
    {"role": "system", "content": "Synthetic test instruction."},
    {"role": "user", "content": "Remember 17."},
    {"role": "assistant", "content": "Stored 17."},
    {"role": "user", "content": "What value?"},
]


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def admission_mode(self):
        key = self.headers.get("Authorization", "")
        for mode in ADMISSION_MODES:
            if key == "Bearer synthetic-" + mode:
                return mode
        return "" if key == "Bearer synthetic-key" else None

    def json_response(self, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def do_GET(self):
        mode = self.admission_mode()
        if mode is None:
            self.send_error(403)
            return
        if mode == "admission-redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/v1/models")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if mode == "admission-cancel":
            time.sleep(2)
        if urlsplit(self.path).path == "/v1/models":
            self.json_response({"data": [{"id": "wrong-model" if mode == "model-mismatch" else MODEL, "owned_by": "mlx-serve", "loaded": True,
                "state": "ready", "created": ADMISSION_MODES.index(mode) + 2 if mode else 1, "context_length": 32768,
                "meta": {"engine": "mlx", "architecture": "qwen4_exp"}}]})
        elif urlsplit(self.path).path == "/props":
            self.json_response({"settings": {"version": "unverified" if mode == "version-mismatch" else "26.10.1", "engine": "mlx"},
                "default_generation_settings": {"n_ctx": 32768}, "memory": {"max_safe_context": 32768}})
        else:
            self.send_error(404)

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 65536:
                self.send_error(400)
                return
            body = json.loads(self.rfile.read(size))
            admission_mode = self.admission_mode()
            if admission_mode is None:
                self.send_error(403)
                return
            if self.path == "/api/show":
                self.json_response({"model_info": {"general.basename": MODEL}, "template": TEMPLATE + ("changed" if admission_mode == "template-mismatch" else "")})
                return
            if self.path == "/tokenize":
                self.json_response({"tokens": [True] if admission_mode == "bad-tokenizer" else [1] * count(body["content"])})
                return
            if self.path == "/v1/chat/completions" and body.get("stream") is False:
                prompt = count(render(body)) + (1 if admission_mode == "count-mismatch" else 0)
                self.json_response({"model": MODEL, "usage": {"prompt_tokens": prompt,
                    "completion_tokens": 1, "total_tokens": prompt + 1}})
                return
            valid = (
                self.path == "/v1/chat/completions"
                and self.headers.get("Authorization") == "Bearer synthetic-key"
                and body.get("messages") == EXPECTED
                and body.get("stream") is True
                and body.get("model") == MODEL
                and body.get("stream_options") == {"include_usage": True}
                and body.get("reasoning_effort") == "none"
                and body.get("chat_template_kwargs") == {"preserve_thinking": True}
                and body.get("enable_thinking") is False
            )
            if not valid:
                self.send_response(400)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            mode = MODES[body["seed"] - 100]
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
            elif mode in ("good", "usage-missing", "usage-mismatch", "stream-model-mismatch"):
                self.event({"choices": [{"delta": {"reasoning_content": "Synthetic reasoning."}, "finish_reason": None}]})
                payload = json.dumps({"choices": [{"delta": {"content": "17日"}, "finish_reason": None}]}, ensure_ascii=False)
                for byte in ("data: " + payload + "\r\n\r\n").encode():
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                self.event({"choices": [{"delta": {}, "finish_reason": "stop"}]})
                prompt = count(render(body))
                if mode != "usage-missing":
                    prompt += 1 if mode == "usage-mismatch" else 0
                    self.event({"model": "wrong-model" if mode == "stream-model-mismatch" else MODEL,
                        "choices": [], "usage": {"prompt_tokens": prompt,
                        "completion_tokens": 2, "total_tokens": prompt + 2,
                        "prompt_tokens_details": {"cached_tokens": 1}}})
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
