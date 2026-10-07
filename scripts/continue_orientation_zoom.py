#!/usr/bin/env python3
"""Continue the exact frozen pilot in a new private directory, without retries.

Preparation is offline by default. --execute enables missing requests;
--fill-unreceived additionally authorizes one fresh dispatch for a prior request
that has no authenticated successful response. Original failures remain intact.
Only content-free metadata is printed. Captured responses are not fresh latency.
"""
from __future__ import annotations

import argparse
from collections import Counter, deque
from concurrent.futures import ThreadPoolExecutor, as_completed
import copy
import hashlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import threading
import time

VERSION = "orientation-zoom-continuation-v1"
PARENT_REPORT_SHA256 = "81cc1582829969ee22cc01c53d4e63d594b10bc03dac14173079cd334122041c"
DEPENDENCIES = frozenset(("evaluate_orientation_zoom.py", "orientation_zoom.py", "orientation_zoom_judging.py",
    "evaluate_answerer_controls.py", "longmemeval_independent_cases.py", "local_longmemeval_qa.py",
    "longmemeval_cases.py", "evaluate_longmemeval.py", "evaluate_answers.py", "evaluation_fixtures.py", "import_chat.py"))
NAME = re.compile(r"[A-Za-z0-9_-]+\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
MAX_FILE = 64 * 1024 * 1024
USAGE_FIELDS = ("input_tokens", "output_tokens", "reasoning_tokens", "cached_input_tokens")


class ContinuationError(Exception):
    """Fixed codes only; never include private content or exception text."""


def require(condition, code):
    if not condition:
        raise ContinuationError(code)


def canonical(value):
    try:
        return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise ContinuationError("canonical_value_invalid") from None


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def strict_json(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value, "duplicate_json_key")
            value[key] = item
        return value
    try:
        return json.loads(raw, object_pairs_hook=pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(ContinuationError("json_constant_invalid")))
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise ContinuationError("json_invalid") from None


def read_file(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_FILE, "file_invalid")
            raw = stream.read(MAX_FILE + 1)
        require(len(raw) <= MAX_FILE, "file_bound_exceeded")
        return raw
    except OSError:
        raise ContinuationError("file_read_failed") from None


def private_write(path, raw):
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    except OSError:
        raise ContinuationError("private_publication_failed") from None


def validate_parent(parent, expected_report_sha=PARENT_REPORT_SHA256):
    require(parent.is_absolute() and not any(path.is_symlink() for path in (parent, *parent.parents)), "parent_path_refused")
    report_raw = read_file(parent / "report.json")
    require(digest(report_raw) == expected_report_sha, "parent_report_pin_mismatch")
    report = strict_json(report_raw)
    declaration_raw = read_file(parent / "declaration.json")
    require(digest(declaration_raw) == report.get("declaration_sha256"), "parent_declaration_pin_mismatch")
    declaration = strict_json(declaration_raw)
    require(not (parent / "source-capture").is_symlink(), "parent_capture_path_refused")
    require(canonical(declaration) == declaration_raw and set(declaration.get("dependencies", {})) == DEPENDENCIES,
        "parent_dependency_inventory_invalid")
    for name, sha in declaration["dependencies"].items():
        require(isinstance(sha, str) and SHA.fullmatch(sha)
            and digest(read_file(parent / "source-capture" / name)) == sha, "parent_source_capture_mismatch")
    for filename, field in (("inputs.json", "inputs_sha256"), ("scorer.json", "scorer_sha256")):
        require(digest(read_file(parent / filename)) == declaration[field], "parent_input_pin_mismatch")
    require(report.get("status") == "terminal" and isinstance(report.get("operations"), dict), "parent_not_terminal")
    return report, declaration


class _CaptureLoader(importlib.abc.Loader):
    def __init__(self, path, sha):
        self.path, self.sha = path, sha

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        raw = read_file(self.path)
        require(digest(raw) == self.sha, "captured_import_changed")
        module.__file__ = str(self.path)
        # Compile authenticated source directly; never load or write .pyc files.
        exec(compile(raw, str(self.path), "exec"), module.__dict__)


class _CaptureFinder(importlib.abc.MetaPathFinder):
    def __init__(self, capture, dependencies):
        self.capture, self.dependencies = capture, {Path(name).stem: (name, sha) for name, sha in dependencies.items()}

    def find_spec(self, fullname, path=None, target=None):
        if fullname in self.dependencies:
            name, sha = self.dependencies[fullname]
            return importlib.util.spec_from_loader(fullname, _CaptureLoader(self.capture / name, sha))
        return None


def load_execution(parent, declaration):
    names = [Path(name).stem for name in declaration["dependencies"]]
    saved = {name: sys.modules.pop(name) for name in names if name in sys.modules}
    finder = _CaptureFinder(parent / "source-capture", declaration["dependencies"])
    old_bytecode = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    sys.meta_path.insert(0, finder)
    try:
        pilot = __import__("evaluate_orientation_zoom")
        require(pilot.pins() == declaration["dependencies"] and pilot.CONFIG == declaration["configuration"], "captured_execution_mismatch")
        for name in names:
            module = sys.modules.get(name)
            if module is not None:
                require(Path(module.__file__).resolve() == (parent / "source-capture" / (name + ".py")).resolve(), "uncaptured_module_refused")
        return pilot
    finally:
        sys.meta_path.remove(finder)
        for name in names:
            sys.modules.pop(name, None)
        sys.modules.update(saved)
        sys.dont_write_bytecode = old_bytecode


class ReplayIndex:
    def __init__(self, parent, report, pilot):
        self.parent, self.pilot, self.operations = parent, pilot, report["operations"]
        self.counts, self.sufficiency = {}, {}
        for name, operation in self.operations.items():
            require(isinstance(name, str) and NAME.fullmatch(name) and isinstance(operation, dict)
                and operation.get("name") == name and operation.get("kind") in ("count", "generation")
                and isinstance(operation.get("request_sha256"), str) and SHA.fullmatch(operation["request_sha256"]), "parent_operation_invalid")
            require(strict_json(read_file(parent / (name + "-operation.json"))) == operation, "parent_operation_receipt_mismatch")
            raw = read_file(parent / (name + "-request.json"))
            require(digest(raw) == operation["request_sha256"] and canonical(strict_json(raw)) == raw, "parent_request_receipt_mismatch")
            if operation.get("received") is True and "failure" not in operation:
                self.response(name, operation)
                if operation["kind"] == "count":
                    self.counts.setdefault(operation["request_sha256"], (name, operation))
                elif name.endswith("-sufficiency"):
                    # This assessment contains no candidate answer. Its exact
                    # body is reusable when an earlier arm was unavailable.
                    try:
                        text, _usage = pilot.parse_response(self.response(name, operation), 1024)
                        pilot.judging.parse_sufficiency(text)
                    except Exception:
                        continue
                    self.sufficiency.setdefault(operation["request_sha256"], (name, operation))

    def response(self, name, operation):
        raw = read_file(self.parent / (name + "-response.json"))
        require(digest(raw) == operation.get("response_sha256"), "parent_response_receipt_mismatch")
        if operation["kind"] == "count":
            value = strict_json(raw)
            require(isinstance(value, dict) and value.get("object") == "response.input_tokens"
                and type(value.get("input_tokens")) is int and value["input_tokens"] > 0, "parent_count_invalid")
        else:
            try:
                _text, usage = self.pilot.parse_response(raw, 16384 if name.endswith("-orientation") else 1024)
            except Exception:
                raise ContinuationError("parent_generation_invalid") from None
            require(usage == operation.get("usage"), "parent_usage_receipt_mismatch")
        return raw

    def match(self, name, kind, request_sha):
        previous = self.operations.get(name)
        if previous is not None:
            require(previous["kind"] == kind and previous["request_sha256"] == request_sha, "parent_stage_request_mismatch")
            if previous.get("received") is True and "failure" not in previous:
                return name, previous
        if kind == "count":
            return self.counts.get(request_sha)
        if kind == "generation" and name.endswith("-sufficiency"):
            return self.sufficiency.get(request_sha)
        return None


class TokenRateGuard:
    def __init__(self, limit=300_000, window=60, now=time.monotonic, sleep=time.sleep):
        self.limit, self.window, self.now, self.sleep = limit, window, now, sleep
        self.entries, self.lock = deque(), threading.Lock()

    def reserve(self, tokens):
        require(type(tokens) is int and 0 <= tokens <= self.limit, "rate_reservation_invalid")
        waited = 0.0
        while True:
            with self.lock:
                current = self.now()
                while self.entries and current - self.entries[0][0] >= self.window:
                    self.entries.popleft()
                if sum(value for _at, value in self.entries) + tokens <= self.limit:
                    self.entries.append((current, tokens))
                    return waited
                delay = min(30.0, self.window - (current - self.entries[0][0]))
            self.sleep(delay); waited += delay


class ReplayAPI:
    def __init__(self, pilot, output, key, declaration, protocol, replay, *, fill_unreceived=False, guard=None,
                 controller_path=None, controller_sha=None, provenance=None):
        self.pilot, self.replay, self.fill_unreceived = pilot, replay, fill_unreceived
        self.guard = guard or TokenRateGuard()
        self.base = pilot.API(output, key, declaration, protocol)
        self.base.request = self.request
        self.original_request = pilot.API.request.__get__(self.base, pilot.API)
        self.provenance, self.halted, self.halt_reason = {}, False, None
        self.controller_path, self.controller_sha = controller_path, controller_sha
        self.controller_provenance = copy.deepcopy(provenance)
        self.controller_provenance_sha = digest(canonical(provenance)) if provenance is not None else None

    def __getattr__(self, name):
        return getattr(self.base, name)

    def frozen(self):
        self.base.frozen()
        if self.controller_path is not None:
            require(digest(read_file(self.controller_path)) == self.controller_sha, "continuation_controller_changed")
            require(digest(read_file(self.output / "source-capture" / self.controller_path.name)) == self.controller_sha,
                "continuation_controller_capture_changed")
        if self.controller_provenance is not None:
            require(digest(read_file(self.output / "continuation-provenance.json")) == self.controller_provenance_sha,
                "continuation_provenance_changed")
        for name, sha in self.declaration["dependencies"].items():
            require(digest(read_file(self.output / "source-capture" / name)) == sha, "continuation_capture_changed")

    def _record_local(self, name, kind, payload, *, raw=None, previous=None, failure=None, mode="retained"):
        require(name not in self.operations, "continuation_stage_duplicate")
        started = time.monotonic()
        self.pilot.client.private_write(self.output / (name + "-request.json"), canonical(payload))
        operation = {"name": name, "kind": kind, "prepared": True, "dispatched": False, "received": raw is not None,
            "request_sha256": digest(canonical(payload)), "elapsed_seconds": 0.0, "continuation_mode": mode}
        if raw is not None:
            self.pilot.client.private_write(self.output / (name + "-response.json"), raw)
            operation["response_sha256"] = digest(raw)
            if kind == "generation":
                operation["usage"] = copy.deepcopy(previous["usage"])
        if failure is not None:
            operation["failure"] = failure
        operation["elapsed_seconds"] = time.monotonic() - started
        self.operations[name] = operation
        self.pilot.private_json(self.output / (name + "-operation.json"), operation)
        return raw

    def request(self, name, kind, payload, reserved_input=0):
        self.frozen()
        require(isinstance(name, str) and NAME.fullmatch(name) and kind in ("count", "generation")
            and name not in self.operations, "continuation_stage_invalid")
        request_sha = digest(canonical(payload))
        matched = self.replay.match(name, kind, request_sha)
        previous = self.replay.operations.get(name)
        if matched is not None:
            parent_name, parent_operation = matched
            raw = self.replay.response(parent_name, parent_operation)
            self.provenance[name] = {"mode": "retained", "parent_name": parent_name,
                "request_sha256": request_sha, "response_sha256": digest(raw),
                "parent_elapsed_seconds": parent_operation.get("elapsed_seconds")}
            return self._record_local(name, kind, payload, raw=raw, previous=parent_operation)
        failure = "continuation_halted_after_429" if self.halted else (
            "prior_unreceived_requires_explicit_fill" if previous is not None and not self.fill_unreceived else None)
        if failure:
            self.provenance[name] = {"mode": "blocked", "request_sha256": request_sha,
                "prior_failure": previous.get("failure") if previous else None, "reason": failure}
            self._record_local(name, kind, payload, previous=previous, failure=failure, mode="blocked")
            raise self.pilot.Error(failure)
        wait = self.guard.reserve(reserved_input + payload["max_output_tokens"]) if kind == "generation" else 0.0
        # Waiting can outlive a source edit; repeat every capture fence directly
        # before handing the prepared request to the original dispatcher.
        self.frozen()
        self.provenance[name] = {"mode": "new", "request_sha256": request_sha,
            "prior_failure": previous.get("failure") if previous else None, "rate_wait_seconds": wait}
        try:
            raw = self.original_request(name, kind, payload, reserved_input=reserved_input)
            self.frozen()
            return raw
        except self.pilot.Error as error:
            if str(error) == "http_status_429":
                self.halted, self.halt_reason = True, "first_new_http_429"
            raise


def prepare(parent, output, protocol, report, declaration, *, execute=False, fill_unreceived=False):
    root = Path(__file__).resolve().parents[1] / ".build" / "evaluation"
    require(output.is_absolute() and output.resolve().is_relative_to(root.resolve())
        and not any(path.is_symlink() for path in (output, *output.parents)), "output_path_refused")
    protocol_raw = read_file(protocol)
    require(digest(protocol_raw) == declaration["official_protocol_sha256"], "protocol_pin_mismatch")
    try:
        output.mkdir(mode=0o700)
        (output / "source-capture").mkdir(mode=0o700)
    except OSError:
        raise ContinuationError("fresh_output_required") from None
    for filename in ("inputs.json", "scorer.json", "declaration.json"):
        private_write(output / filename, read_file(parent / filename))
    for name in declaration["dependencies"]:
        private_write(output / "source-capture" / name, read_file(parent / "source-capture" / name))
    controller_raw = read_file(Path(__file__))
    private_write(output / "source-capture" / Path(__file__).name, controller_raw)
    private_write(output / "qa-protocol.py", protocol_raw)
    provenance = {"version": VERSION, "parent_report_sha256": digest(read_file(parent / "report.json")),
        "parent_declaration_sha256": report["declaration_sha256"], "controller_sha256": digest(controller_raw),
        "frozen_dependencies": declaration["dependencies"], "inputs_sha256": declaration["inputs_sha256"],
        "scorer_sha256": declaration["scorer_sha256"], "source_sha256": declaration["source_sha256"],
        "official_protocol_sha256": declaration["official_protocol_sha256"], "workers": 1,
        "generation_reuse_key": ["stage_name", "kind", "request_sha256"], "count_reuse_key": "canonical_request_sha256",
        "source_only_sufficiency_reuse_exception": "valid_label_and_exact_canonical_request_sha256",
        "reserved_token_rate_limit": 300000, "rolling_seconds": 60, "automatic_retries": 0,
        "stop_after_first_new_http_429": True,
        "execute_authorized": execute,
        "fill_unreceived_authorized": fill_unreceived,
        "new_request_limits": {key: declaration["configuration"][key] for key in (
            "maximum_http_calls", "maximum_generation_calls", "maximum_observed_input_tokens", "maximum_observed_output_tokens")},
        "reused_timings_are_fresh_latency": False}
    private_write(output / "continuation-provenance.json", canonical(provenance))
    return provenance


def usage(operations):
    return {key: sum(operation.get("usage", {}).get(key, 0) for operation in operations) for key in USAGE_FIELDS}


def terminal_report(api, results, parent_report, provenance):
    summaries = {}
    for arm in api.pilot.ARMS:
        rows = [row for row in results if row["arm"] == arm]
        summaries[arm] = {"declared": 30, "operational_complete": sum(row["operational_complete"] for row in rows),
            **{"qa_" + answer: sum(row["qa"] == answer for row in rows) for answer in ("yes", "no", "unknown")},
            "supported_qa_yes": sum(row["qa"] == "yes" and row["support"] == "yes" and row["citation_support"] == "yes" for row in rows),
            "sufficient_yes": sum(row["sufficiency"] == "yes" for row in rows),
            "tool_actions": sum(row["tool_actions"] for row in rows),
            "positive_turns": sum(row.get("positive_turns", 0) for row in rows),
            "full_positive_turns_delivered": sum(row.get("full_positive_turns_delivered", 0) for row in rows),
            "memory_p95_seconds": None, "episode_p95_seconds_excluding_judges": None, "summary_creation_p95_seconds": None}
    by_key = {(row["case"], row["arm"]): row for row in results}
    pairs = {}
    for arm in api.pilot.ARMS[1:]:
        counts = Counter()
        for qid in api.pilot.CASE_IDS:
            baseline, candidate = by_key[qid, api.pilot.ARMS[0]]["qa"], by_key[qid, arm]["qa"]
            counts["unknown" if "unknown" in (baseline, candidate) else
                "wins" if candidate == "yes" and baseline != "yes" else
                "losses" if baseline == "yes" and candidate != "yes" else
                "both_yes" if baseline == "yes" else "both_no"] += 1
        pairs[arm] = {key: counts[key] for key in ("wins", "losses", "both_yes", "both_no", "unknown")}
    new = [operation for name, operation in api.operations.items() if api.provenance[name]["mode"] == "new"]
    retained = [operation for name, operation in api.operations.items() if api.provenance[name]["mode"] == "retained"]
    new_usage, retained_usage = usage(new), usage(retained)
    return {"version": VERSION, "status": "terminal", "parent_report_sha256": provenance["parent_report_sha256"],
        "declaration_sha256": digest(read_file(api.output / "declaration.json")), "continuation_provenance": provenance,
        "summaries": summaries, "paired_qa": pairs, "attempts": results, "operations": api.operations,
        "operation_provenance": api.provenance, "usage_new_receipts": new_usage, "usage_retained_captures": retained_usage,
        "usage_prior_run_observed": parent_report["usage"],
        "usage_cumulative_observed": {key: parent_report["usage"].get(key, 0) + new_usage[key] for key in USAGE_FIELDS},
        "new_observed_standard_generation_cost_estimate_usd": (2 * new_usage["input_tokens"] + 10 * new_usage["output_tokens"]) / 1000000,
        "new_http_calls": api.http_calls, "new_generation_calls": api.generation_calls,
        "retained_request_response_pairs": len(retained), "blocked_request_stages": sum(value["mode"] == "blocked" for value in api.provenance.values()),
        "new_held_input_tokens_including_unknown": api.reserved_input, "new_held_output_tokens_including_unknown": api.reserved_output,
        "prior_held_input_tokens_including_unknown": parent_report["held_input_tokens_including_unknown"],
        "prior_held_output_tokens_including_unknown": parent_report["held_output_tokens_including_unknown"],
        "prior_unknown_generation_receipts": parent_report["unknown_generation_receipts"],
        "new_unknown_generation_receipts": sum(operation["kind"] == "generation" and "usage" not in operation for operation in new),
        "prior_failures": dict(Counter(operation.get("failure") for operation in parent_report["operations"].values() if "failure" in operation)),
        "dispatch_halted": api.halted, "halt_reason": api.halt_reason,
        "quality_semantics": "same_frozen_experiment_with_stage_specific_responses_and_exact_body_source_only_sufficiency_cache",
        "timing_semantics": "cached_continuation_orchestration_not_fresh_product_latency",
        "native_application_measured": False, "representative_accuracy_established": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent", type=Path, default=Path(__file__).resolve().parents[1] / ".build/evaluation/orientation-zoom-v1-20261006")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--protocol", type=Path, required=True)
    parser.add_argument("--api-key-file", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--fill-unreceived", action="store_true")
    args = parser.parse_args()
    sys.dont_write_bytecode = True
    parent_report, declaration = validate_parent(args.parent)
    pilot = load_execution(args.parent, declaration)
    replay = ReplayIndex(args.parent, parent_report, pilot)
    provenance = prepare(args.parent, args.output, args.protocol, parent_report, declaration,
        execute=args.execute, fill_unreceived=args.fill_unreceived)
    print(json.dumps({"prepared": True, "parent_report_sha256": provenance["parent_report_sha256"],
        "controller_sha256": provenance["controller_sha256"], "declared_attempts": 90}), flush=True)
    if not args.execute:
        return
    require(args.api_key_file is not None, "credential_missing")
    try:
        key = read_file(args.api_key_file).decode().strip()
    except UnicodeError:
        raise ContinuationError("credential_invalid") from None
    if key.startswith("OPENAI_API_KEY="):
        key = key.split("=", 1)[1].strip().strip("\"'")
    require(bool(key) and "\n" not in key and "\r" not in key, "credential_invalid")
    api = ReplayAPI(pilot, args.output, key, declaration, args.output / "qa-protocol.py", replay,
        fill_unreceived=args.fill_unreceived, controller_path=Path(__file__), controller_sha=provenance["controller_sha256"],
        provenance=provenance)
    cases = strict_json(read_file(args.output / "inputs.json"))["cases"]
    scorers = {row["question_id"]: row for row in strict_json(read_file(args.output / "scorer.json"))["cases"]}
    require(tuple(case["question_id"] for case in cases) == pilot.CASE_IDS and set(scorers) == set(pilot.CASE_IDS), "case_inventory_invalid")
    results = []
    with ThreadPoolExecutor(max_workers=1) as workers:
        futures = {workers.submit(pilot.execute_case, api, case, scorers[case["question_id"]], args.output / "qa-protocol.py"): case["question_id"] for case in cases}
        for future in as_completed(futures):
            qid = futures[future]
            try:
                results.extend(future.result())
            except Exception:
                for arm in pilot.ARMS:
                    path = args.output / f"{qid}-{arm}-result.json"
                    if path.exists():
                        results.append(strict_json(read_file(path)))
                        continue
                    row = {"case": qid, "arm": arm, "operational_complete": False, "qa": "unknown", "sufficiency": "unknown",
                        "support": "unknown", "citation_support": "unknown", "tool_actions": 0, "failure": "case_failed_or_dispatch_unavailable",
                        "positive_turns": len(scorers[qid]["positive_ids"]), "gold_sessions": len(scorers[qid]["gold_sessions"]),
                        "full_positive_turns_delivered": 0, "gold_sessions_delivered": 0}
                    private_write(path, canonical(row)); results.append(row)
    api.frozen()
    results.sort(key=lambda row: (pilot.CASE_IDS.index(row["case"]), pilot.ARMS.index(row["arm"])))
    require(len(results) == 90, "terminal_denominator_invalid")
    final = terminal_report(api, results, parent_report, provenance)
    private_write(args.output / "report.json", canonical(final))
    print(json.dumps({"terminal": True, "summaries": final["summaries"], "new_http_calls": api.http_calls,
        "new_generation_calls": api.generation_calls, "dispatch_halted": api.halted, "report_sha256": digest(canonical(final))}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"failure": str(error) if isinstance(error, ContinuationError) else "continuation_failed"}), flush=True)
        sys.exit(1)
