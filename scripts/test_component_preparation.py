"""Exercise the actual answering coordinator with a declared synthetic tokenizer."""
import importlib.util
import argparse
import json
from pathlib import Path
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("boros_public_endpoint_fixture", ROOT / "Tests/endpoint_fixture.py")
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
MODEL, TEMPLATE = FIXTURE.MODEL, FIXTURE.TEMPLATE
BLOCKS = re.compile(r"<\|im_start\|>(system|user|assistant)\n(.*?)<\|im_end\|>\n", re.S)
BARRIERS = {name: (threading.Event(), threading.Event()) for name in ("cancel", "deadline")}
OBSERVED = {"full_counts": [], "recent_counts": [], "evidence_counts": [], "created": [], "identity_drifts": set()}
MODEL_READS = {}
LOCK = threading.Lock()


def synthetic_count(text):
    """Deliberately non-vocabulary oracle; production /tokenize remains tested separately."""
    blocks = BLOCKS.findall(text)
    is_full = bool(blocks and blocks[0][0] == "system")
    if is_full and "fixtureMandatory" in blocks[-1][1]:
        return 40000
    marked = any(marker in text for marker in ("fixturePipeline", "fixtureBoundary", "fixtureBarrier", "fixtureIdentity"))
    if is_full and not marked:
        return FIXTURE.count(text)
    evidence = sum(content.count("BEGIN HISTORICAL SOURCE") for _, content in blocks)
    evidence_unit = 4000 if "fixture-boundary-archive" in text else 5000
    recent = len(blocks) - (2 if is_full else 0) - int(bool(evidence))
    result = (100 if is_full else 0) + recent * 4000 + evidence * evidence_unit
    with LOCK:
        key = "full_counts" if is_full else "evidence_counts" if evidence else "recent_counts"
        OBSERVED[key].append(result)
    if not is_full:
        for case, marker in (("cancel", "fixtureBarrierCancel"), ("deadline", "fixtureBarrierDeadline")):
            if marker in text:
                ready, release = BARRIERS[case]
                ready.set()
                if not release.wait(10):
                    raise TimeoutError("Synthetic barrier was not released.")
    return result


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def mode(self):
        authorization = self.headers.get("Authorization", "")
        prefix = "Bearer synthetic-"
        return authorization[len(prefix):] if authorization.startswith(prefix) else ""

    def drifting(self):
        with LOCK:
            return MODEL_READS.get(self.mode(), 0) >= 2

    def send_json(self, payload, status=200):
        encoded = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parts = urlparse(self.path)
        if parts.path == "/fixture-wait":
            case = parse_qs(parts.query).get("case", [""])[0]
            pair = BARRIERS.get(case)
            self.send_json({"ready": bool(pair and pair[0].wait(10))})
        elif parts.path == "/v1/models":
            mode = self.mode()
            with LOCK:
                MODEL_READS[mode] = MODEL_READS.get(mode, 0) + 1
                created = 1770000000 + len(OBSERVED["created"]) + 1
                OBSERVED["created"].append(created)
                drift = mode == "component-model-drift" and MODEL_READS[mode] >= 2
                if drift:
                    OBSERVED["identity_drifts"].add(mode)
            self.send_json({"data": [{"id": "foreign-synthetic-model" if drift else MODEL,
                                      "created": created, "owned_by": "mlx-serve", "loaded": True,
                                      "state": "ready", "context_length": 32768, "max_model_len": 32768,
                                      "capabilities": ["chat", "streaming"], "input_modalities": ["text"],
                                      "meta": {"engine": "mlx", "architecture": "qwen4_exp"}}]})
        elif parts.path == "/props":
            drift = self.mode() == "component-version-drift" and self.drifting()
            if drift:
                with LOCK:
                    OBSERVED["identity_drifts"].add(self.mode())
            self.send_json({"settings": {"version": "unsupported-synthetic-version" if drift else "26.10.1", "engine": "mlx"},
                            "default_generation_settings": {"n_ctx": 32768},
                            "memory": {"max_safe_context": 32768}})
        else:
            self.send_json({"error": "Unsupported synthetic fixture request."}, 404)

    def do_POST(self):
        parts = urlparse(self.path)
        if parts.path == "/fixture-release":
            case = parse_qs(parts.query).get("case", [""])[0]
            pair = BARRIERS.get(case)
            if pair:
                pair[1].set()
            self.send_json({"released": bool(pair)})
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        except (ValueError, TypeError):
            self.send_json({"error": "Malformed synthetic fixture request."}, 400)
            return
        if parts.path == "/api/show":
            template_drift = self.mode() == "component-template-drift" and self.drifting()
            model_drift = self.mode() == "component-model-drift" and self.drifting()
            if template_drift:
                with LOCK:
                    OBSERVED["identity_drifts"].add(self.mode())
            self.send_json({"model_info": {"general.basename": "foreign-synthetic-model" if model_drift else MODEL},
                            "template": TEMPLATE + ("\nsynthetic template change" if template_drift else "")})
        elif parts.path == "/tokenize":
            try:
                count = synthetic_count(body["content"])
            except (KeyError, TypeError, TimeoutError):
                self.send_json({"error": "Synthetic count fixture failed."}, 500)
                return
            self.send_json({"tokens": [1] * count})
        elif parts.path == "/v1/chat/completions" and body.get("stream") is False and body.get("max_tokens") == 1:
            count = synthetic_count(FIXTURE.render(body))
            self.send_json({"model": MODEL, "choices": [{"message": {"content": "4"}, "finish_reason": "stop"}],
                            "usage": {"prompt_tokens": count, "completion_tokens": 1, "total_tokens": count + 1}})
        else:
            self.send_json({"error": "Answer inference is outside this preparation fixture."}, 400)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/boros/Boros.app/Contents/MacOS/Boros")
    binary = parser.parse_args().binary.resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        checks = {}
        failed_process = False
        for suite in ("--component-preparation-integration-test", "--retrieval-strategy-integration-test",
                      "--answer-coordinator-integration-test"):
            result = subprocess.run([str(binary), suite, f"http://127.0.0.1:{server.server_port}/v1"],
                                    capture_output=True, text=True, timeout=100)
            suite_checks = json.loads(result.stdout)
            if not isinstance(suite_checks, dict) or not suite_checks or not all(isinstance(value, bool) for value in suite_checks.values()):
                raise ValueError("Invalid content-free preparation check report.")
            if checks.keys() & suite_checks.keys():
                raise ValueError("Duplicate preparation check identity.")
            checks.update(suite_checks)
            failed_process |= bool(result.returncode)
        with LOCK:
            checks["component_preparation_fixture_created_varies_every_model_observation"] = len(OBSERVED["created"]) > 3 and all(
                earlier < later for earlier, later in zip(OBSERVED["created"], OBSERVED["created"][1:]))
            checks["component_preparation_fixture_observed_actual_identity_drift"] = OBSERVED["identity_drifts"] == {
                "component-model-drift", "component-template-drift", "component-version-drift"}
            checks["component_preparation_fixture_observed_recent_geometric_counts"] = all(
                value in OBSERVED["recent_counts"] for value in (28000, 12000, 4000, 8000))
            checks["component_preparation_fixture_observed_evidence_geometric_counts"] = all(
                value in OBSERVED["evidence_counts"] for value in (35000, 15000, 5000, 12000))
            checks["component_preparation_fixture_observed_whole_recount"] = all(
                value in OBSERVED["full_counts"] for value in (100, 9100, 4100, 20100))
        failed = [name for name, passed in checks.items() if passed is not True]
        print(json.dumps({"suite": "component-preparation", "checks": len(checks), "failed": failed}))
        return int(bool(failed_process or failed))
    finally:
        for _, release in BARRIERS.values():
            release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Component preparation verification failed before all checks completed.")
        raise SystemExit(1)
