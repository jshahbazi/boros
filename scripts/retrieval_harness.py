#!/usr/bin/env python3
"""P1 offline retrieval harness: case-level candidate (R1) and delivered (R2) recall.

Runs the shared selected-Qwen answer coordinator in disposable stores against a
loopback stand-in for mlx-serve whose /tokenize uses a pinned copy of the
selected model's tokenizer. Every attempt stops at the answering boundary, so
no answer is generated and no paid or remote request is made. Annotations are
used only by this scorer and by a separate declared-source feasibility
control; the selection process never receives them. Reports contain
identifiers, counts and timings, never source text, questions or answers.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import heapq
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

MODEL = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
TOKENIZER_SHA256 = "0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3"
DEFAULT_TOKENIZER = Path.home() / ".mlx-serve/models" / MODEL / "tokenizer.json"
DATASET = ".build/datasets/longmemeval-98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json"
HUNDRED_SELECTION_MANIFEST_SHA256 = "2e310e440a7aca2fa24b8474b6afe1f2115a654851b37f8948acef995649f8ae"
TEMPLATE = (ROOT / "Tests/qwen38-chat-template.jinja").read_text()
HARNESS_SOURCE = "Tests/Evaluation/DeliveryHarness.swift"
EXCLUDED_SOURCES = ("BonsaiPlayground.swift",)
# A cached baseline store is reused only while the code that writes stores and
# the semantic sidecar is unchanged. Retrieval and packing changes reuse it.
INGESTION_SOURCES = ("MemoryStore.swift", "SemanticIndex.swift", "BackgroundIndexBudget.swift",
    "BackgroundIndexWorker.swift", "BackgroundIndexJournal.swift", "EventSourceTime.swift", "SourceTimeSchema.swift",
    "EpisodeAccountingJournal.swift", "ContextComponentJournal.swift", "AuthoritySchemaFive.swift",
    "AuthoritySchemaSix.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift", "AuthoritySchemaNine.swift")
# P2 step 4 arms (docs/P2-SEMANTIC-DECISION.md): hybrid strategy with every
# eligible chunk searched, under the shipped fusion or lexical-first fill.
GLOBAL_ARMS = ("global_hybrid", "global_fill")
ARMS = ("recent_only", "lexical", "hybrid") + GLOBAL_ARMS
PRIMARY_ARM = "hybrid"
# Declared before measurement: the ranked candidate list traced by the v1/16
# assembler, which is also the number of evidence spans it may deliver.
DECLARED_CANDIDATE_DEPTH = 16
KNOWN_MISSES = ("51c32626", "1b9b7252", "4baee567", "1a1907b4")
PROCESS_TIMEOUT = 1800


class HarnessError(Exception):
    """Carries only fixed host-authored reason strings."""


def require(condition, code):
    if not condition:
        raise HarnessError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def private_write(path: Path, data: bytes):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def percentile(values, fraction):
    ordered = sorted(v for v in values if v is not None)
    if not ordered:
        return None
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def default_source():
    """The pinned dataset in this checkout, else in the repository's primary checkout."""
    common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=ROOT,
                            capture_output=True, text=True).stdout.strip()
    for base in (ROOT, Path(common).parent if common else ROOT):
        if (base / DATASET).exists():
            return base / DATASET
    return ROOT / DATASET


def load_fixture_renderer():
    spec = importlib.util.spec_from_file_location("boros_endpoint_fixture", ROOT / "Tests/endpoint_fixture.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.render


# ---------------------------------------------------------------- endpoint --

class OfflineEndpoint:
    """Loopback mlx-serve stand-in. Counts with the pinned tokenizer; refuses generation."""

    def __init__(self, tokenizer_path: Path, parity_sample: int, tokenizer=None):
        if tokenizer is None:
            raw = tokenizer_path.read_bytes()
            require(digest(raw) == TOKENIZER_SHA256, "tokenizer_pin_mismatch")
            from tokenizers import Tokenizer
            tokenizer = Tokenizer.from_str(raw.decode())
            # mlx-serve 26.10.1 /tokenize does not apply the file's NFC
            # normalizer: decomposed marks stay separate tokens there. Measured
            # October 8, 2026; the parity check below detects any change.
            tokenizer.normalizer = None
        # Synthetic tests inject an object with the same encode(...).ids shape.
        self.tokenizer = tokenizer
        self.render = load_fixture_renderer()
        self.lock = threading.Lock()
        self.counters = {"tokenize": 0, "calibration": 0, "refused_generation": 0, "metadata": 0, "rejected": 0}
        self.parity_sample = parity_sample
        self.sample = []  # max-heap by negated digest: keeps the smallest digests
        endpoint = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, value, status=200):
                data = json.dumps(value, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def refuse(self, status):
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self):
                endpoint.bump("metadata")
                path = urlsplit(self.path).path
                if path == "/v1/models":
                    self.reply({"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "mlx-serve",
                        "loaded": True, "state": "ready", "created": 1791463722,
                        "context_length": 219136, "max_model_len": 219136,
                        "capabilities": ["chat", "tool_use", "streaming", "vision", "reasoning", "json_schema"],
                        "input_modalities": ["text", "image", "video"],
                        "meta": {"engine": "mlx", "architecture": "qwen4_exp"}}]})
                elif path == "/props":
                    self.reply({"settings": {"version": "26.10.1", "engine": "mlx"},
                        "default_generation_settings": {"n_ctx": 219136}, "memory": {"max_safe_context": 262144}})
                else:
                    self.refuse(404)

            def do_POST(self):
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 1 <= size <= 16 * 1024 * 1024:
                        endpoint.bump("rejected"); self.refuse(400); return
                    body = json.loads(self.rfile.read(size))
                    path = urlsplit(self.path).path
                    if path == "/api/show":
                        endpoint.bump("metadata")
                        self.reply({"model_info": {"general.basename": MODEL}, "template": TEMPLATE})
                    elif path == "/tokenize":
                        content = body["content"]
                        ids = endpoint.encode(content)
                        endpoint.record(content, len(ids))
                        self.reply({"tokens": ids})
                    elif path == "/v1/chat/completions" and body.get("stream") is False and body.get("max_tokens") == 1:
                        # Admission calibration: report the rendered prompt count
                        # without running any model.
                        endpoint.bump("calibration")
                        prompt = len(endpoint.encode(endpoint.render(body)))
                        self.reply({"model": MODEL, "usage": {"prompt_tokens": prompt, "completion_tokens": 1,
                                                              "total_tokens": prompt + 1}})
                    else:
                        endpoint.bump("refused_generation"); self.refuse(503)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception:
                    # Never print request bodies or exception text.
                    endpoint.bump("rejected")
                    try:
                        self.refuse(400)
                    except Exception:
                        pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}/v1/"

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.server.shutdown()
        self.server.server_close()

    def encode(self, text):
        return self.tokenizer.encode(text, add_special_tokens=False).ids

    def bump(self, name):
        with self.lock:
            self.counters[name] += 1

    def record(self, content, count):
        key = digest(content.encode())
        with self.lock:
            self.counters["tokenize"] += 1
            if self.parity_sample <= 0 or any(item[1] == key for item in self.sample):
                return
            entry = (_Reverse(key), key, content, count)
            if len(self.sample) < self.parity_sample:
                heapq.heappush(self.sample, entry)
            elif key < self.sample[0][1]:
                heapq.heapreplace(self.sample, entry)

    def parity(self, live_url):
        """Compare offline counts with the live server's /tokenize on the same strings."""
        if not live_url:
            return {"status": "not_checked"}
        checked = matched = identical = 0
        largest = 0
        mismatches = []
        try:
            for _reverse, _key, content, count in sorted(self.sample, key=lambda item: item[1]):
                request = urllib.request.Request(live_url.rstrip("/") + "/tokenize",
                    data=json.dumps({"model": MODEL, "content": content}).encode(),
                    headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=60) as response:
                    live = json.load(response)["tokens"]
                checked += 1
                matched += len(live) == count
                offline = self.encode(content)
                identical += live == offline
                largest = max(largest, abs(len(live) - count))
                if live != offline and len(mismatches) < 8:
                    mismatches.append(self.mismatch(content, live, offline))
        except Exception:
            return {"status": "live_tokenizer_unavailable", "checked": checked, "count_matches": matched}
        return {"status": "checked", "selection": "smallest_content_sha256", "checked": checked,
                "count_matches": matched, "token_id_matches": identical, "largest_count_difference": largest,
                "mismatches": mismatches}

    def mismatch(self, content, live, offline):
        """Content-free divergence description: positions and Unicode categories only."""
        import unicodedata
        first = next((i for i, (a, b) in enumerate(zip(live, offline)) if a != b), min(len(live), len(offline)))
        prefix = len(self.tokenizer.decode(offline[:first])) if hasattr(self.tokenizer, "decode") else None
        window = content[prefix:prefix + 8] if prefix is not None else ""
        return {"characters": len(content), "live_tokens": len(live), "offline_tokens": len(offline),
                "first_divergent_token": first, "divergent_character_offset": prefix,
                "window_categories": [unicodedata.category(c) for c in window],
                "window_code_point_classes": ["ascii" if ord(c) < 128 else "bmp" if ord(c) < 0x10000 else "astral" for c in window]}


class _Reverse:
    def __init__(self, key):
        self.key = key

    def __lt__(self, other):
        return self.key > other.key


# ----------------------------------------------------------------- cohorts --

def load_cohort(name, source):
    import jevk5_saved_qa as jev
    if name == "development":
        import native_investigation_hundred_cases as hundred
        histories, manifest = hundred.prepare(source)
        artifacts = {}
        for ordinal, history in enumerate(histories):
            artifacts[f"input-{ordinal}.json"] = digest(jev.canonical(hundred.runner_input(history)))
            artifacts[f"scorer-{ordinal}.json"] = digest(jev.canonical(history))
        manifest["artifacts"] = artifacts
        manifest_sha = digest(jev.canonical(manifest))
        require(manifest_sha == HUNDRED_SELECTION_MANIFEST_SHA256, "development_manifest_mismatch")
        configuration = dict(hundred.CONFIGURATION)
        pins = "frozen native-investigation-100-v1 selection manifest reproduced from the pinned source"
    elif name == "regression":
        import longmemeval_independent_cases as independent
        histories, manifest = independent.prepare_with_manifest(source)
        manifest_sha = digest(jev.canonical(manifest))
        configuration = dict(independent.CONFIGURATION)
        pins = "fourteen-history independent cohort; native projection pins verified by its case module"
    else:
        raise HarnessError("unknown_cohort")
    cases = []
    for history in histories:
        probe = history["episodes"][0]
        events = [{key: event[key] for key in ("id", "project_id", "conversation_key", "role", "status", "text", "source_time")}
                  for event in history["events"]]
        sizes = {event["id"]: len(event["text"].encode()) for event in events}
        positives = [label["event_id"] for label in history["source_labels"] if label.get("has_answer") is True]
        require(all(identifier in sizes for identifier in positives), "positive_label_unresolved")
        cases.append({"question_id": probe["question_id"], "question_type": probe["question_type"],
            "abstention": probe["abstention"], "events": events, "sizes": sizes, "positives": positives,
            "question": {key: probe[key] for key in ("project_id", "conversation_key", "prompt", "question_time")},
            "projection_sha256": digest(canonical({"events": events, "question": {key: probe[key] for key in (
                "project_id", "conversation_key", "prompt", "question_time")}}))})
    return cases, {"cohort": name, "manifest_sha256": manifest_sha, "pins": pins, "cases": len(cases),
                   "source_sha256": manifest["source"]["sha256"]}, configuration


# ----------------------------------------------------------------- harness --

def compile_harness(cache_root: Path):
    sources = sorted(p for p in (ROOT / "Sources/Boros").glob("*.swift") if p.name not in EXCLUDED_SOURCES)
    files = [*sources, ROOT / HARNESS_SOURCE, ROOT / "Sources/CSQLite/module.modulemap", ROOT / "Sources/CSQLite/shim.h"]
    hashes = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in files}
    build_digest = digest(canonical(hashes))
    directory = cache_root / "bin" / build_digest
    binary = directory / "DeliveryHarness"
    if not binary.exists():
        staging = cache_root / "bin" / (".staging-" + build_digest[:16] + "-" + str(os.getpid()))
        shutil.rmtree(staging, ignore_errors=True)
        captured = staging / "source"
        for path in files:
            destination = captured / path.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(path.read_bytes())
        command = ["/usr/bin/swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
                   "-framework", "AppKit", "-framework", "Foundation", "-framework", "Security",
                   "-framework", "LocalAuthentication", "-framework", "NaturalLanguage",
                   "-I", str(captured / "Sources/CSQLite"), "-lsqlite3", "-o", str(staging / "DeliveryHarness"),
                   *(str(captured / name) for name in hashes if name.endswith(".swift"))]
        process = subprocess.run(command, capture_output=True, timeout=1200)
        require(process.returncode == 0, "harness_compilation_failed")
        directory.parent.mkdir(parents=True, exist_ok=True)
        if not directory.exists():
            os.replace(staging, directory)
            shutil.rmtree(directory / "source", ignore_errors=True)
        else:
            shutil.rmtree(staging, ignore_errors=True)
    ingestion = digest(canonical({name: hashes["Sources/Boros/" + name] for name in INGESTION_SOURCES}
                                  | {HARNESS_SOURCE: hashes[HARNESS_SOURCE]}))
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain", "--", "Sources", "Tests", "scripts"], cwd=ROOT,
                                capture_output=True, text=True).stdout.strip())
    return binary, {"git_revision": revision, "working_tree_modified": dirty, "build_sha256": build_digest,
                    "binary_sha256": digest(binary.read_bytes()), "ingestion_sha256": ingestion,
                    "compiled_sources": len(hashes), "excluded_sources": list(EXCLUDED_SOURCES)}


def run_process(binary, mode, document, scratch: Path, label):
    directory = Path(tempfile.mkdtemp(prefix=label + "-", dir=scratch))
    try:
        source = directory / "input.json"
        output = directory / "output.json"
        document = dict(document, work_directory=str(directory / "work"))
        private_write(source, canonical(document))
        started = time.monotonic()
        try:
            process = subprocess.run([str(binary), mode, str(source), str(output)], capture_output=True,
                                     timeout=PROCESS_TIMEOUT, env={**os.environ, "BOROS_DATA_DIR": str(directory / "data")})
        except subprocess.TimeoutExpired:
            return {"process_failure": "timeout", "wall_milliseconds": (time.monotonic() - started) * 1000}
        wall = (time.monotonic() - started) * 1000
        if process.returncode or not output.exists():
            return {"process_failure": "exit_" + str(process.returncode), "wall_milliseconds": wall}
        result = json.loads(output.read_bytes())
        result["wall_milliseconds"] = wall
        return result
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def run_case(case, binary, configuration, store_root, scratch, ingestion_sha, rebuild):
    key = digest(canonical([ingestion_sha, case["projection_sha256"]]))
    cache = store_root / key
    if rebuild:
        shutil.rmtree(cache, ignore_errors=True)
    base = {"version": 1, "cache_directory": str(cache), "events": case["events"], "question": case["question"],
            "configuration": configuration}
    # The selection process never receives annotations.
    selection = run_process(binary, "select", {**base, "arms": list(ARMS), "declared_source_ids": None},
                            scratch, "select")
    control = None
    if not case["abstention"] and case["positives"]:
        if len(case["positives"]) > 16:
            control = {"declared_limit_exceeded": True}
        else:
            control = run_process(binary, "control", {**base, "arms": ["declared_sources"],
                                  "declared_source_ids": case["positives"]}, scratch, "control")
    return selection, control


# ----------------------------------------------------------------- scoring --

def coverage(attempt, sizes):
    """Per event: union of delivered byte ranges, and whether it arrived whole."""
    ranges = {}
    for identifier in attempt.get("recent_source_ids", []):
        ranges.setdefault(identifier, []).append((0, sizes.get(identifier, 0)))
    for item in attempt.get("evidence", []):
        ranges.setdefault(item["event_id"], []).append((item["offset"], item["offset"] + item["bytes"]))
    whole, partial = set(), set()
    for identifier, spans in ranges.items():
        spans.sort()
        reach = 0
        for start, end in spans:
            if start > reach:
                break
            reach = max(reach, end)
        if identifier in sizes and reach >= sizes[identifier]:
            whole.add(identifier)
        if any(end > start for start, end in spans):
            partial.add(identifier)
    return whole, partial


def score_attempt(attempt, case):
    positives = case["positives"]
    if attempt is None or not attempt.get("preparation_completed"):
        failure = None if attempt is None else attempt.get("failure") or attempt.get("failure_stage")
        return {"failure": failure or "missing_attempt", "candidate": 0, "whole": 0, "partial": 0,
                "positives": len(positives), "turns": []}
    whole, partial = coverage(attempt, case["sizes"])
    recent = set(attempt.get("recent_source_ids", []))
    ranks = {}
    for item in attempt.get("candidates", []):
        if item.get("rank") is not None and item["rank"] < DECLARED_CANDIDATE_DEPTH:
            ranks.setdefault(item["event_id"], item["rank"])
    turns = []
    for identifier in positives:
        turns.append({"recent": identifier in recent, "candidate_rank": ranks.get(identifier),
                      "candidate": identifier in recent or identifier in ranks or identifier in whole,
                      "whole": identifier in whole, "partial": identifier in partial})
    return {"failure": None, "positives": len(positives), "turns": turns,
            "candidate": sum(t["candidate"] for t in turns), "whole": sum(t["whole"] for t in turns),
            "partial": sum(t["partial"] for t in turns),
            "trace_omitted": bool(attempt.get("trace_omitted")),
            "candidate_count": attempt.get("candidate_count"),
            "prompt_tokens": attempt.get("prompt_tokens"),
            "components": attempt.get("components"),
            "selection": {key: value for key, value in (attempt.get("selection") or {}).items()
                          if key.endswith("Count") or key.endswith("Rounds")},
            "retrieval_mode": (attempt.get("retrieval") or {}).get("mode"),
            "preparation_milliseconds": attempt.get("preparation_milliseconds")}


def feasibility(control, case):
    if case["abstention"] or not case["positives"]:
        return "not_answerable"
    if control is None:
        return "control_missing"
    if control.get("declared_limit_exceeded"):
        return "infeasible_declared_limit"
    attempts = control.get("attempts") or []
    if control.get("process_failure") or len(attempts) != 1 or not attempts[0].get("preparation_completed"):
        return "control_failed"
    attempt = attempts[0]
    whole, _partial = coverage(attempt, case["sizes"])
    selection = attempt.get("selection") or {}
    reduced = sum(int(selection.get(name) or 0) for name in ("evidenceTokenExcludedCount", "evidenceEnvelopeExcludedCount",
                                                             "evidenceByteExcludedCount", "evidenceRowExcludedCount"))
    if all(identifier in whole for identifier in case["positives"]) and reduced == 0:
        return "feasible"
    return "infeasible"


def rate(numerator, denominator):
    return {"passed": numerator, "cases": denominator,
            "fraction": round(numerator / denominator, 4) if denominator else None}


def summarize(rows):
    answerable = [row for row in rows if row["feasibility"] not in ("not_answerable",)]
    # Infeasible cases leave the R denominators. Control failures stay in them.
    eligible = [row for row in answerable if not row["feasibility"].startswith("infeasible")]
    summary = {"declared_cases": len(rows), "answerable_cases": len(answerable), "eligible_cases": len(eligible),
               "feasibility": {}, "arms": {}}
    for row in rows:
        summary["feasibility"][row["feasibility"]] = summary["feasibility"].get(row["feasibility"], 0) + 1
    categories = sorted({row["question_type"] for row in rows})
    for arm in ARMS:
        scored = [(row, row["arms"][arm]) for row in eligible]
        r1 = sum(s["failure"] is None and s["candidate"] == s["positives"] for _, s in scored)
        r2 = sum(s["failure"] is None and s["whole"] == s["positives"] for _, s in scored)
        turns = sum(s["positives"] for _, s in scored)
        by_category = {}
        for category in categories:
            subset = [s for row, s in scored if row["question_type"] == category]
            by_category[category] = {"cases": len(subset),
                "r1": sum(s["failure"] is None and s["candidate"] == s["positives"] for s in subset),
                "r2": sum(s["failure"] is None and s["whole"] == s["positives"] for s in subset)}
        all_attempts = [row["arms"][arm] for row in rows]
        summary["arms"][arm] = {
            "r1_candidate_recall": rate(r1, len(scored)),
            "r2_delivered_recall": rate(r2, len(scored)),
            "turn_candidate": rate(sum(s["candidate"] for _, s in scored), turns),
            "turn_delivered_whole": rate(sum(s["whole"] for _, s in scored), turns),
            "turn_delivered_any_bytes": rate(sum(s["partial"] for _, s in scored), turns),
            "by_category": by_category,
            "failures": sum(s["failure"] is not None for s in all_attempts),
            "trace_omitted": sum(bool(s.get("trace_omitted")) for s in all_attempts),
            "prompt_tokens_p50": percentile([s.get("prompt_tokens") for s in all_attempts], 0.5),
            "prompt_tokens_p95": percentile([s.get("prompt_tokens") for s in all_attempts], 0.95),
            "preparation_milliseconds_p50": percentile([s.get("preparation_milliseconds") for s in all_attempts], 0.5),
            "preparation_milliseconds_p95": percentile([s.get("preparation_milliseconds") for s in all_attempts], 0.95)}
    return summary


def diagnostic(attempt):
    """Content-free per-arm detail for the P2 step 4 diagnosis: ranked candidate
    identities and byte ranges, delivered ranges, primary order, expansion
    decisions and semantic paths and ranks."""
    if not attempt or not attempt.get("preparation_completed"):
        return None
    return {"candidates": [[item.get("event_id"), item.get("offset"), item.get("bytes")] for item in attempt.get("candidates", [])],
            "evidence": [[item["event_id"], item["offset"], item["bytes"]] for item in attempt.get("evidence", [])],
            "semantic": attempt.get("semantic_diagnostics")}


def global_semantic_summary(rows):
    """Latency and population of the explicitly selected global search arms."""
    result = {}
    for arm in GLOBAL_ARMS:
        audits = [((row.get("diagnostics") or {}).get(arm) or {}).get("semantic") or {} for row in rows]
        audits = [item.get("global_semantic") for item in audits if isinstance(item, dict) and item.get("global_semantic")]
        timing = {name: [a["milliseconds"][name] for a in audits] for name in ("lexical", "encode", "vector_scan", "vector_loop", "fuse", "read", "total")}
        vectors = [a["eligible_vector_rows"] for a in audits]
        result[arm] = {"searches": len(audits), "eligible_vector_rows_p50": percentile(vectors, 0.5),
                       "eligible_vector_rows_max": max(vectors) if vectors else None,
                       "vector_bytes_scanned_max": max(vectors) * 512 * 4 if vectors else None,
                       "milliseconds": {name: {"p50": percentile(values, 0.5), "p95": percentile(values, 0.95),
                                               "max": max(values) if values else None} for name, values in timing.items()},
                       "parameters_sha256": sorted({a["parameters_sha256"] for a in audits})}
    return result


def known_miss_rows(rows):
    result = {}
    for row in rows:
        if row["question_id"] in KNOWN_MISSES:
            result[row["question_id"]] = {"question_type": row["question_type"], "feasibility": row["feasibility"],
                "positives": row["positives"],
                "arms": {arm: {"candidate": row["arms"][arm]["candidate"], "whole": row["arms"][arm]["whole"],
                               "turns": row["arms"][arm]["turns"], "failure": row["arms"][arm]["failure"]}
                         for arm in ARMS}}
    return result


# -------------------------------------------------------------------- main --

def run(args):
    output = args.output.absolute()
    require(not output.exists() and not output.is_symlink(), "output_exists")
    started = time.monotonic()
    print("Loading pinned cohort; annotations stay in the scorer.", flush=True)
    cases, cohort, configuration = load_cohort(args.cohort, args.source)
    if args.limit:
        cases = cases[:args.limit]
    cache_root = (ROOT / ".build/retrieval-harness").absolute()
    cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    print("Compiling captured Boros sources with the delivery harness.", flush=True)
    binary, implementation = compile_harness(cache_root)
    endpoint = OfflineEndpoint(args.tokenizer, args.parity_sample).start()
    configuration = dict(configuration, endpoint=endpoint.url)
    rows = []
    try:
        with tempfile.TemporaryDirectory(prefix="boros-retrieval-harness-") as temporary:
            scratch = Path(temporary)
            os.chmod(scratch, 0o700)
            print(f"Running {len(cases)} histories x {len(ARMS)} arms offline; no answering requests.", flush=True)
            done = [0]
            lock = threading.Lock()

            def work(case):
                selection, control = run_case(case, binary, configuration, cache_root / "stores", scratch,
                                              implementation["ingestion_sha256"], args.rebuild_stores)
                with lock:
                    done[0] += 1
                    if done[0] % 10 == 0 or done[0] == len(cases):
                        print(f"  {done[0]}/{len(cases)} histories", flush=True)
                return case, selection, control

            with ThreadPoolExecutor(max_workers=args.workers) as pool:
                results = list(pool.map(work, cases))
        for case, selection, control in results:
            attempts = {item.get("arm"): item for item in (selection.get("attempts") or [])}
            cache = selection.get("cache") or {}
            rows.append({"question_id": case["question_id"], "question_type": case["question_type"],
                "abstention": case["abstention"], "positives": len(case["positives"]),
                "feasibility": feasibility(control, case),
                "process_failure": selection.get("process_failure"),
                "harness_wall_milliseconds": selection.get("wall_milliseconds"),
                "cache_reused": cache.get("reused"), "ingest_milliseconds": cache.get("ingest_milliseconds"),
                "semantic": cache.get("semantic"),
                "runner_started": any(item.get("runner_started") for item in attempts.values())
                    or any(item.get("runner_started") for item in ((control or {}).get("attempts") or [])),
                "arms": {arm: score_attempt(attempts.get(arm), case) for arm in ARMS},
                "diagnostics": {arm: diagnostic(attempts.get(arm)) for arm in ARMS if arm != "recent_only"}})
        parity = endpoint.parity(args.live_tokenizer)
    finally:
        endpoint.stop()
    require(not any(row["runner_started"] for row in rows), "answer_runner_started")
    summary = summarize(rows)
    semantic = [row["semantic"] or {} for row in rows]
    report = {"retrieval_harness_version": 1, "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "purpose": "P1 offline candidate and delivered recall for the ordinary selected-Qwen path",
        "stage_measured": "R1 candidate recall and R2 delivered recall; no answers, judges or end-to-end quality",
        "cohort": cohort, "configuration": {key: value for key, value in configuration.items() if key not in ("endpoint", "system")}
            | {"system_sha256": digest(configuration["system"].encode())},
        "component_policy": "ContextComponentPolicy.currentSelectedQwen (v1/16)",
        "arms": {"recent_only": "recent_only strategy", "lexical": "hybrid strategy without a semantic index",
                 "hybrid": "hybrid strategy with the history's semantic index, as ordinary Send",
                 "global_hybrid": "hybrid strategy, every eligible chunk searched, shipped reciprocal-rank fusion (evaluation option)",
                 "global_fill": "hybrid strategy, every eligible chunk searched, lexical primaries first, semantic fills empty slots (evaluation option)"},
        "definitions": {
            "r1": f"every annotated positive turn is delivered, in recent context, or among the first {DECLARED_CANDIDATE_DEPTH} ranked candidates traced before span and token limits",
            "r2": "every annotated positive turn is delivered whole (union of delivered byte ranges covers the source) after component token fitting and admission",
            "feasible": "a separate declared-source control delivers every positive turn whole with no evidence exclusions under the same caps",
            "denominator": "answerable cases minus infeasible ones; preparation and control failures stay in it"},
        "tokenizer": {"sha256": TOKENIZER_SHA256, "parity": parity},
        "endpoint_counters": endpoint.counters,
        "implementation": implementation,
        "summary": summary, "known_misses": known_miss_rows(rows),
        "global_semantic": global_semantic_summary(rows),
        "semantic_index": {"histories": len(semantic),
            "construction_failures": sum(bool(item.get("failure")) for item in semantic),
            "paused": sum(item.get("pause_reason") not in (None,) for item in semantic if "pause_reason" in item),
            "failed_chunks": sum(int(item.get("failed_chunks") or 0) for item in semantic),
            "published_chunks": sum(int(item.get("published_chunks") or 0) for item in semantic),
            "milliseconds_p50": percentile([item.get("milliseconds") for item in semantic], 0.5),
            "milliseconds_p95": percentile([item.get("milliseconds") for item in semantic], 0.95)},
        "cases": rows,
        "provider_requests": {"answer_generation": 0, "remote": 0},
        "wall_seconds": round(time.monotonic() - started, 1),
        "limitations": ["one replicate; selection is deterministic but unreplicated across builds",
                        "LongMemEval positive-turn annotations are a proxy for sufficient source spans",
                        "store caches are reused across runs; ingestion and indexing timings come from the build that created them",
                        "the parity sample covers a deterministic subset of counted strings, not every request"]}
    private_write(output, canonical(report) + b"\n")
    for arm in ARMS:
        values = summary["arms"][arm]
        print(json.dumps({"arm": arm, "r1": values["r1_candidate_recall"], "r2": values["r2_delivered_recall"],
                          "turns_whole": values["turn_delivered_whole"], "failures": values["failures"]}, sort_keys=True))
    print(json.dumps({"feasibility": summary["feasibility"], "parity": parity, "endpoint": endpoint.counters}, sort_keys=True))
    print("Metadata-only report: " + str(output))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cohort", choices=("development", "regression"), required=True)
    parser.add_argument("--output", type=Path, required=True, help="New metadata-only JSON report; never overwritten")
    parser.add_argument("--source", type=Path, default=None, help="Pinned longmemeval_s_cleaned.json")
    parser.add_argument("--tokenizer", type=Path, default=DEFAULT_TOKENIZER, help="Pinned selected-model tokenizer.json")
    parser.add_argument("--live-tokenizer", default=None,
                        help="Optional live server base URL, e.g. http://localhost:11234; checks /tokenize parity only")
    parser.add_argument("--parity-sample", type=int, default=64)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="Run only the first N declared cases (diagnostic)")
    parser.add_argument("--rebuild-stores", action="store_true")
    args = parser.parse_args()
    args.source = args.source or default_source()
    if not (1 <= args.workers <= 16 and 0 <= args.parity_sample <= 1024 and args.limit >= 0):
        parser.error("limits outside supported ranges")
    try:
        run(args)
    except HarnessError as error:
        print("Retrieval harness failed: " + str(error) + ".", file=sys.stderr)
        return 1
    except Exception:
        if os.environ.get("BOROS_HARNESS_DEBUG") == "1":
            raise
        # Library exceptions can quote input material; print a fixed reason.
        print("Retrieval harness failed. Check the pinned source, tokenizer, compiler and a new output path.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
