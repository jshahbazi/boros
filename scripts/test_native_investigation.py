"""Synthetic native investigation transport; never reads models or private chats."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("boros_native_component_fixture", ROOT / "scripts/test_component_preparation.py")
COMPONENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPONENT)
FIXTURE = COMPONENT.FIXTURE
LOCK = threading.Lock()
OBSERVED = {}
BARRIERS = {mode: (threading.Event(), threading.Event()) for mode in ("cancel_planner", "deadline_planner")}
PRIVATE_MARKERS = ("BOROS MEMORY PLANNER", "BOROS MEMORY EXTRACTION")


class SyntheticServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, client_address)


def observed_state(mode):
    return OBSERVED.setdefault(mode, {"planner": 0, "extraction": 0, "final": 0,
                                      "calibration": 0, "metadata": 0, "tokenize": 0,
                                      "private_original_ids_absent": True,
                                      "private_records": 0, "final_has_original_pair": False})


def stage_count(text, mode):
    # The pin-release case needs a full 16-span selection to reach planning;
    # use the existing byte-vocabulary oracle for every count in that case.
    return FIXTURE.count(text) if mode == "pin_release" else COMPONENT.synthetic_count(text)


def planner_data(messages):
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        try:
            value = json.loads(message.get("content", ""))
        except (ValueError, TypeError):
            continue
        if isinstance(value, dict) and isinstance(value.get("selected_block_ids"), list):
            return value
    return {}


def records_from(messages):
    records = []

    def visit(value):
        if isinstance(value, list):
            for item in value:
                visit(item)
        elif isinstance(value, dict):
            if isinstance(value.get("event_id"), str) and isinstance(value.get("content"), str):
                records.append(value)
            else:
                for item in value.values():
                    visit(item)

    for message in messages:
        if message.get("role") != "user":
            continue
        try:
            visit(json.loads(message.get("content", "")))
        except (ValueError, TypeError):
            pass
    return records


class Handler(COMPONENT.Handler):
    def mode(self):
        authorization = self.headers.get("Authorization", "")
        prefix = "Bearer synthetic-native-"
        if authorization.startswith(prefix):
            return authorization[len(prefix):]
        return super().mode()

    def do_GET(self):
        parts = urlparse(self.path)
        if parts.path == "/native-fixture-wait":
            mode = parse_qs(parts.query).get("mode", [""])[0]
            pair = BARRIERS.get(mode)
            self.send_json({"ready": bool(pair and pair[0].wait(15))})
            return
        if self.mode() == "admission-cancel":
            time.sleep(0.2)
        if parts.path in ("/v1/models", "/props"):
            with LOCK:
                observed_state(self.mode())["metadata"] += 1
        super().do_GET()

    def do_POST(self):
        parts = urlparse(self.path)
        if parts.path == "/native-fixture-release":
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            mode = parse_qs(parts.query).get("mode", [""])[0]
            pair = BARRIERS.get(mode)
            if pair:
                pair[1].set()
            self.send_json({"released": bool(pair)})
            return
        if parts.path == "/tokenize":
            with LOCK:
                observed_state(self.mode())["tokenize"] += 1
        if parts.path == "/tokenize" and self.mode() == "pin_release":
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                self.send_json({"tokens": [1] * stage_count(body["content"], self.mode())})
            except (ValueError, TypeError, KeyError):
                self.send_json({"error": "Synthetic count fixture failed."}, 400)
            return
        if parts.path != "/v1/chat/completions":
            super().do_POST()
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if body.get("stream") is False and body.get("max_tokens") == 1:
                with LOCK:
                    observed_state(self.mode())["calibration"] += 1
                count = stage_count(FIXTURE.render(body), self.mode())
                self.send_json({"model": FIXTURE.MODEL,
                                "choices": [{"message": {"content": "4"}, "finish_reason": "stop"}],
                                "usage": {"prompt_tokens": count, "completion_tokens": 1, "total_tokens": count + 1}})
                return
            messages = body.get("messages")
            if not isinstance(messages, list) or body.get("stream") is not True:
                self.send_json({"error": "Unsupported synthetic generation."}, 400)
                return
            system = messages[0].get("content", "")
            stage = "planner" if PRIVATE_MARKERS[0] in system else "extraction" if PRIVATE_MARKERS[1] in system else "final"
            mode = self.mode()
            with LOCK:
                state = observed_state(mode)
                state[stage] += 1
                planner_number = state["planner"]
                if stage != "final":
                    encoded = json.dumps(messages, ensure_ascii=False)
                    state["private_original_ids_absent"] &= "native-original-" not in encoded
                    state["private_records"] += len(records_from(messages))
                    if mode == "pin_release" and stage == "planner":
                        selected = planner_data(messages).get("selected_block_ids", [])
                        if planner_number == 1:
                            state["initial_full_pack"] = len(selected) == 8
                            state["initial_sources"] = len(records_from(messages))
                        elif planner_number == 2:
                            state["pins_blocked_first_search"] = all("Lisbon" not in row["content"] for row in records_from(messages))
                        elif planner_number == 3:
                            state["released_search_reached_correction"] = any("Lisbon" in row["content"] for row in records_from(messages))
                else:
                    encoded = json.dumps(messages, ensure_ascii=False)
                    state["final_has_original_pair"] = "native-original-correction-human" in encoded and "native-original-correction-assistant" in encoded
            if stage == "planner":
                if mode == "malformed_plan":
                    answer = "{\"action\":\"finish\",\"action\":\"search\"}"
                else:
                    search = planner_number <= 2 if mode == "pin_release" else planner_number == 1
                    pins = planner_data(messages).get("selected_block_ids", []) if mode == "pin_release" and planner_number == 1 else []
                    answer = json.dumps({"action": "search" if search else "finish",
                                         "query": "navigationCompass" if search else "",
                                         "region_id": "", "cursor": None, "time_filter": None,
                                         "pin_block_ids": pins, "missing_facts": []}, separators=(",", ":"))
            elif stage == "extraction":
                selected = records_from(messages)
                candidates = [row for row in selected if row.get("role") == "assistant" and "Lisbon" in row["content"]]
                if not candidates:
                    self.send_json({"error": "Synthetic extraction received no correction evidence."}, 400)
                    return
                chosen = candidates[-1]
                quote = "Invented synthetic text absent from every source." if mode == "invalid_quote" else chosen["content"]
                answer = json.dumps({"facts": [{"claim": "Synthetic private claim navigationCompass destination is Lisbon.",
                                                "source_ids": [chosen["event_id"]],
                                                "quotes": [{"source_id": chosen["event_id"], "text": quote}]}],
                                     "unresolved": []}, separators=(",", ":"))
            else:
                answer = "Synthetic final Lisbon [native-original-correction-assistant]."
            if stage == "planner" and mode == "private_empty_output":
                answer = ""
            finish_reason = "length" if stage == "planner" and mode == "private_output_bound" else "stop"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            if stage == "planner" and mode in BARRIERS:
                ready, release = BARRIERS[mode]
                ready.set()
                if not release.wait(15):
                    self.close_connection = True
                    return
            self.event({"choices": [{"delta": {"content": answer}, "finish_reason": None}]})
            self.event({"choices": [{"delta": {}, "finish_reason": finish_reason}]})
            if not (stage == "planner" and mode == "private_usage_missing"):
                prompt = stage_count(FIXTURE.render(body), mode)
                self.event({"model": FIXTURE.MODEL, "choices": [],
                            "usage": {"prompt_tokens": prompt, "completion_tokens": 2, "total_tokens": prompt + 2}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
        except (ValueError, TypeError, KeyError, BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value, separators=(",", ":")) + "\n\n").encode())
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/boros/Boros.app/Contents/MacOS/Boros")
    binary = parser.parse_args().binary.resolve()
    server = SyntheticServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        checks = {}
        for flag in ("--investigation-stage-preparation-integration-test", "--native-investigation-integration-test"):
            result = subprocess.run([str(binary), flag, f"http://127.0.0.1:{server.server_port}/v1"],
                                    capture_output=True, text=True, timeout=150)
            values = json.loads(result.stdout)
            if not isinstance(values, dict) or not values or not all(isinstance(value, bool) for value in values.values()):
                raise ValueError("Invalid metadata-only synthetic report.")
            checks.update(values)
            checks["native_fixture_" + flag.removeprefix("--") + "_exit_zero"] = result.returncode == 0
        with LOCK:
            success = OBSERVED.get("success", {})
            checks["native_fixture_deliberate_search_then_extraction_then_final"] = success.get("planner", 0) >= 1 and success.get("extraction") == 1 and success.get("final") == 1
            checks["native_fixture_private_original_ids_are_opaque"] = all(state["private_original_ids_absent"] for state in OBSERVED.values())
            checks["native_fixture_extraction_received_selected_originals"] = success.get("private_records", 0) >= 2
            checks["native_fixture_final_received_complete_correction_exchange"] = success.get("final_has_original_pair") is True
            release = OBSERVED.get("pin_release", {})
            checks["native_fixture_pin_release_started_with_full_pinned_selection"] = release.get("initial_full_pack") is True and release.get("initial_sources") == 16
            checks["native_fixture_pin_release_first_search_cannot_replace_pins"] = release.get("pins_blocked_first_search") is True
            checks["native_fixture_pin_release_repeated_search_reaches_correction"] = release.get("planner", 0) >= 3 and release.get("released_search_reached_correction") is True
            checks["native_fixture_pin_release_reaches_extraction_and_final"] = release.get("extraction") == 1 and release.get("final") == 1 and release.get("final_has_original_pair") is True
            reformulation = OBSERVED.get("initial_query_reformulation", {})
            checks["native_fixture_initial_query_reformulation_reaches_answer"] = reformulation.get("planner", 0) >= 2 and reformulation.get("extraction") == 1 and reformulation.get("final") == 1
            for mode in ("cancel_planner", "deadline_planner", "malformed_plan", "invalid_quote", "private_usage_missing",
                         "private_output_bound", "private_empty_output"):
                state = OBSERVED.get(mode, {})
                checks["native_fixture_" + mode + "_private_stage_reached"] = state.get("planner", 0) >= 1
                checks["native_fixture_" + mode + "_final_dispatch_fenced"] = state.get("final", 0) == 0
            stage_counts = {mode: {name: state[name] for name in ("metadata", "tokenize", "calibration", "planner", "extraction", "final")}
                            for mode, state in OBSERVED.items()}
        print(json.dumps({"passed": sum(checks.values()), "total": len(checks),
                          "failed": sorted(key for key, value in checks.items() if not value),
                          "stage_counts": stage_counts}, sort_keys=True))
        return 0 if all(checks.values()) else 1
    finally:
        for _, release in BARRIERS.values():
            release.set()
        for _, release in COMPONENT.BARRIERS.values():
            release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Native investigation verification failed before all checks completed.")
        raise SystemExit(1)
