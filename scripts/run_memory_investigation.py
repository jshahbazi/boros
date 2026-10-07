#!/usr/bin/env python3
"""Prepare a private single-case investigation; provider execution is explicit.

Import and the default CLI mode do not read credentials or call a provider.
There is no cohort selection, scoring, answer reference or label input. Existing
experiment captures are never reused or altered by this runner.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
from decimal import Decimal, InvalidOperation, ROUND_FLOOR
import json
from pathlib import Path
import re
import sys
import time

import evaluate_answerer_controls as client
import orientation_zoom as originals

VERSION = "memory-investigation-runner-v1"
MODEL = "gpt-6.1-sol"
INPUT_RATE_MICROUSD = 2
OUTPUT_RATE_MICROUSD = 10
MAXIMUM_INPUT_BYTES = 64 * 1024 * 1024
MAXIMUM_REQUEST_BYTES = 2 * 1024 * 1024
MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
MAXIMUM_PROVIDER_ADMISSION_SECONDS = 300
STAGE_BOUNDS = {"plan": 1024, "extract": 2048, "answer": 1024}
PLAN_STAGE = re.compile(r"plan_([0-9]{1,2})\Z")
DEPENDENCIES = ("run_memory_investigation.py", "memory_investigation.py",
                "history_navigation.py", "evaluate_answerer_controls.py", "orientation_zoom.py")
SAFE_CODE = re.compile(r"[a-z][a-z0-9_]{0,95}\Z")
Error = client.DiagnosticError
require = client.require


def canonical(value):
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True,
                          separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise Error("canonical_value_invalid") from None


def safe_failure(error, fallback):
    """Known codes only. Arbitrary exception strings may contain private data."""
    if isinstance(error, KeyboardInterrupt):
        return "investigation_cancelled"
    code = str(error) if isinstance(error, (Error, originals.ExperimentError)) else ""
    return code if SAFE_CODE.fullmatch(code) else fallback


def read_bytes(path, maximum, code):
    try:
        with Path(path).open("rb") as stream:
            raw = stream.read(maximum + 1)
    except (OSError, ValueError):
        raise Error(code) from None
    require(len(raw) <= maximum, code)
    return raw


def private_write(path, raw):
    try:
        client.private_write(path, raw)
    except Exception:
        raise Error("private_capture_failed") from None


def private_json(path, value):
    private_write(path, canonical(value))


def cost_cap_microusd(value):
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        raise Error("cost_cap_invalid") from None
    require(amount.is_finite() and amount > 0, "cost_cap_invalid")
    micros = int((amount * 1_000_000).to_integral_value(rounding=ROUND_FLOOR))
    require(micros > 0, "cost_cap_invalid")
    return micros


def usd(micros):
    return format(Decimal(micros) / Decimal(1_000_000), ".6f")


def validate_case(raw):
    case = client.strict_json(raw)
    require(isinstance(case, dict) and set(case) == {"question", "question_date", "sources"},
            "case_fields_invalid")
    require(isinstance(case["question"], str) and case["question"].strip()
            and isinstance(case["question_date"], str) and case["question_date"].strip(),
            "question_invalid")
    require(len(case["question"].encode()) <= 16384
            and len(case["question_date"].encode()) <= 512, "question_bound_invalid")
    canonical(case)
    # History validates exact source fields, unique IDs and ordered complete turns.
    try:
        history = originals.History(case["sources"])
    except originals.ExperimentError:
        raise Error("source_inventory_invalid") from None
    finally:
        # The old pure-history validator owns an in-memory SQLite handle.
        if "history" in locals():
            history.close()
    return case


def dependency_pins():
    here = Path(__file__).resolve().parent
    return {name: client.digest(read_bytes(here / name, MAXIMUM_INPUT_BYTES,
                                         "dependency_read_failed")) for name in DEPENDENCIES}


def create_output(output):
    output = Path(output)
    root = Path(__file__).resolve().parents[1] / ".build" / "evaluation"
    require(output.is_absolute(), "output_path_refused")
    require(output != root and output.is_relative_to(root), "output_path_refused")
    # Resolve only after rejecting symlink ancestors: an existing link may escape
    # the ignored root even when its spelled path appears to be contained there.
    require(not any(path.is_symlink() for path in (output, *output.parents)), "output_path_refused")
    require(output.resolve() != root.resolve()
            and output.resolve().is_relative_to(root.resolve()), "output_path_refused")
    require(not output.exists(), "output_exists")
    try:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        output.mkdir(mode=0o700)
    except OSError:
        raise Error("output_create_failed") from None
    require(output.stat().st_mode & 0o777 == 0o700, "output_permissions_invalid")
    return output


def prepare(input_path, output, maximum_cost_usd=None):
    """Freeze originals and implementation and render a private offline map."""
    from history_navigation import NavigationHistory
    from memory_investigation import InvestigationLimits

    cap = cost_cap_microusd(maximum_cost_usd) if maximum_cost_usd is not None else None
    input_path = Path(input_path).absolute()
    raw = read_bytes(input_path, MAXIMUM_INPUT_BYTES, "input_read_failed")
    case = validate_case(raw)
    history = NavigationHistory(case["sources"])
    limits = asdict(InvestigationLimits())
    pins = dependency_pins()
    try:
        preview = history.overview(page_size=8)
        manifest = history.manifest()
    finally:
        history.close()
    output = create_output(output)
    private_write(output / "input-original.json", raw)
    private_json(output / "case.json", case)
    private_json(output / "navigation-preview.json", preview)
    private_json(output / "identity-manifest.json", manifest)
    capture = output / "source-capture"
    capture.mkdir(mode=0o700)
    for name, expected in pins.items():
        dependency = read_bytes(Path(__file__).resolve().parent / name,
                                MAXIMUM_INPUT_BYTES, "dependency_read_failed")
        require(client.digest(dependency) == expected, "implementation_changed")
        private_write(capture / name, dependency)
    frozen_files = {name: client.digest((output / name).read_bytes()) for name in
                    ("input-original.json", "case.json", "navigation-preview.json", "identity-manifest.json")}
    frozen_files.update({"source-capture/" + name: expected for name, expected in pins.items()})
    declaration = {
        "version": VERSION, "model": MODEL, "reasoning_effort": "low",
        "input_path": str(input_path), "input_sha256": client.digest(raw),
        "dependencies": pins, "frozen_files": frozen_files, "limits": limits,
        "maximum_cost_microusd": cap,
        "maximum_provider_admission_seconds": MAXIMUM_PROVIDER_ADMISSION_SECONDS,
        "in_flight_transport_timeout_seconds": 120,
        "preflight_maximum_reserved_cost_usd": usd(
            limits["reserved_input_tokens"] * INPUT_RATE_MICROUSD
            + limits["reserved_output_tokens"] * OUTPUT_RATE_MICROUSD),
        "preflight_is_upper_bound_not_actual_price": True,
        "spending_cap_may_terminate_before_answer": True,
        "pricing": {"input_microusd_per_token": INPUT_RATE_MICROUSD,
                    "output_microusd_per_token": OUTPUT_RATE_MICROUSD,
                    "cached_input_discount_applied": False,
                    "full_output_reserve_includes_reasoning": True},
        "execution_default": False, "has_scoring_inputs": False,
        "counts": {"source_records": len(case["sources"]),
                   "source_sessions": len({row["session_index"] for row in case["sources"]})},
    }
    private_json(output / "declaration.json", declaration)
    verify_prepared(output, declaration)
    return declaration


def verify_prepared(output, declaration):
    """Recheck the live source, every frozen artifact and live implementation."""
    output = Path(output)
    require(not any(path.is_symlink() for path in (output, *output.parents)), "frozen_path_changed")
    require(output.stat().st_mode & 0o777 == 0o700, "frozen_permissions_changed")
    declaration_path = output / "declaration.json"
    require(not declaration_path.is_symlink()
            and declaration_path.stat().st_mode & 0o777 == 0o600, "frozen_permissions_changed")
    require(read_bytes(declaration_path, MAXIMUM_INPUT_BYTES, "declaration_read_failed")
            == canonical(declaration), "declaration_changed")
    require(dependency_pins() == declaration["dependencies"], "implementation_changed")
    raw = read_bytes(declaration["input_path"], MAXIMUM_INPUT_BYTES, "input_read_failed")
    require(client.digest(raw) == declaration["input_sha256"], "input_changed")
    for name, expected in declaration["frozen_files"].items():
        path = output / name
        require(not path.is_symlink() and not path.parent.is_symlink(), "frozen_path_changed")
        require(path.stat().st_mode & 0o777 == 0o600, "frozen_permissions_changed")
        require(client.digest(read_bytes(path, MAXIMUM_INPUT_BYTES, "frozen_read_failed")) == expected,
                "frozen_artifact_changed")


def parse_response(raw, expected_input, maximum_output, visible_output):
    """Accept only complete, bounded Sol replies with a complete usage receipt."""
    require(type(raw) is bytes and len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
    value = client.strict_json(raw)
    require(isinstance(value, dict) and value.get("model") == MODEL
            and value.get("status") == "completed" and value.get("error") is None,
            "model_or_completion_invalid")
    usage = client.parse_usage("openai", value)
    require(usage["input_tokens"] == expected_input, "generation_count_mismatch")
    require(usage["output_tokens"] <= maximum_output
            and usage["nonreasoning_output_upper_bound"] <= visible_output,
            "stage_output_bound_exceeded")
    output = value.get("output")
    require(isinstance(output, list), "output_invalid")
    parts = []
    for item in output:
        require(isinstance(item, dict), "output_invalid")
        if item.get("type") == "reasoning":
            continue
        require(item.get("type") == "message" and item.get("role") == "assistant"
                and item.get("status") == "completed" and isinstance(item.get("content"), list),
                "output_invalid")
        for part in item["content"]:
            require(isinstance(part, dict) and part.get("type") == "output_text"
                    and isinstance(part.get("text"), str), "refusal_or_output_invalid")
            parts.append(part["text"])
    content = "\n".join(parts)
    require(bool(content.strip()), "empty_output")
    require(len(content.encode()) <= visible_output * 32, "stage_output_byte_bound_exceeded")
    canonical(content)
    return content, usage


class OpenAIProvider:
    """Serial provider with immutable captures and irreversible call fences.

    Reservations never decrease, including after observed usage. This bounds
    both successful requests and unknown charged work at conservative rates.
    The transport and frozen check are injectable only for synthetic tests.
    """
    def __init__(self, output, key, declaration, *, http_fn=None, frozen_check=None, clock_fn=None):
        self.output, self.key, self.declaration = Path(output), key, declaration
        self.http = http_fn or client.http
        self.check_frozen = frozen_check or (lambda: verify_prepared(self.output, self.declaration))
        self.clock = clock_fn or time.monotonic
        self.started = self.clock()
        self.maximum_elapsed = declaration.get("maximum_provider_admission_seconds", MAXIMUM_PROVIDER_ADMISSION_SECONDS)
        require(type(self.maximum_elapsed) is int and 0 < self.maximum_elapsed <= MAXIMUM_PROVIDER_ADMISSION_SECONDS,
                "admission_deadline_invalid")
        self.maximum_cost = declaration.get("maximum_cost_microusd")
        require(type(self.maximum_cost) is int and self.maximum_cost > 0, "cost_cap_required")
        require(isinstance(key, str) and key and "\n" not in key and "\r" not in key,
                "credential_format_invalid")
        self.limits = declaration["limits"]
        self.fenced = False
        self.failure = None
        self.operations = []
        self.count_cache = {}
        self.count_calls = self.generation_calls = self.http_calls = 0
        self.reserved_input = self.reserved_output = self.reserved_cost = 0
        self.observed_input = self.observed_output = self.observed_cost = 0

    def _limit(self, name, default):
        value = self.limits.get(name, default)
        require(type(value) is int and value > 0, "limit_invalid")
        return value

    def _check(self):
        require(not self.fenced, "provider_fenced")
        try:
            require(self.clock() - self.started < self.maximum_elapsed, "provider_admission_deadline_exceeded")
            self.check_frozen()
        except (Exception, KeyboardInterrupt) as error:
            self.fenced, self.failure = True, safe_failure(error, "frozen_check_failed")
            raise Error(self.failure) from None

    def _messages(self, messages):
        require(isinstance(messages, list) and messages, "messages_invalid")
        for message in messages:
            require(isinstance(message, dict) and set(message) == {"role", "content"}
                    and message["role"] in ("system", "user", "assistant")
                    and isinstance(message["content"], str), "messages_invalid")
        require(len(canonical(messages)) <= MAXIMUM_REQUEST_BYTES, "request_bound_exceeded")

    def _dispatch(self, kind, payload, expected_input=0, stage=None):
        self._check()
        require(self.http_calls < self._limit("maximum_count_calls", 128)
                + self._limit("max_generation_calls", 9), "http_call_budget_exhausted")
        if kind == "count":
            require(self.count_calls < self._limit("maximum_count_calls", 128), "count_budget_exhausted")
            self.count_calls += 1
        else:
            require(self.generation_calls < self._limit("max_generation_calls", 9), "generation_budget_exhausted")
            output = payload["max_output_tokens"]
            reserve = expected_input * INPUT_RATE_MICROUSD + output * OUTPUT_RATE_MICROUSD
            require(self.reserved_cost + reserve <= self.maximum_cost, "cost_cap_exhausted")
            require(self.reserved_input + expected_input <= self._limit("reserved_input_tokens", 150000)
                    and self.reserved_output + output <= self._limit("reserved_output_tokens", 16384),
                    "aggregate_token_budget_exhausted")
            self.generation_calls += 1
            self.reserved_input += expected_input
            self.reserved_output += output
            self.reserved_cost += reserve
        self.http_calls += 1
        name = f"operation-{self.http_calls:04d}"
        raw_request = canonical(payload)
        require(len(raw_request) <= MAXIMUM_REQUEST_BYTES, "request_bound_exceeded")
        operation = {"operation": self.http_calls, "kind": kind, "stage": stage,
                     "request_sha256": client.digest(raw_request), "dispatched": False,
                     "response_received": False, "usage_status": "unknown" if kind == "generation" else "not_applicable",
                     "reserved_input_tokens": expected_input,
                     "reserved_output_tokens": payload.get("max_output_tokens", 0),
                     "reserved_cost_microusd": expected_input * INPUT_RATE_MICROUSD
                         + payload.get("max_output_tokens", 0) * OUTPUT_RATE_MICROUSD}
        self.operations.append(operation)
        started = time.monotonic()
        try:
            private_write(self.output / (name + "-request.json"), raw_request)
            # Capture itself may have taken time; pin again immediately before dispatch.
            self._check()
            endpoint = "https://api.openai.com/v1/responses" + ("/input_tokens" if kind == "count" else "")
            operation["dispatched"] = True
            raw = self.http(endpoint, payload, self.key)
            require(type(raw) is bytes and len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
            require(self.key.encode() not in raw, "credential_echo_refused")
            operation["response_received"] = True
            operation["response_sha256"] = client.digest(raw)
            private_write(self.output / (name + "-response.json"), raw)
            self._check()
            if kind == "generation":
                # Preserve independently valid usage even if stage parsing fails.
                # The full admission reservation remains held either way.
                usage = client.parse_usage("openai", client.strict_json(raw))
                operation.update(usage_status="observed_provider_receipt", usage=usage)
                self.observed_input += usage["input_tokens"]
                self.observed_output += usage["output_tokens"]
                self.observed_cost += usage["input_tokens"] * INPUT_RATE_MICROUSD + usage["output_tokens"] * OUTPUT_RATE_MICROUSD
                stage_kind = "plan" if PLAN_STAGE.fullmatch(stage) else stage
                content, _ = parse_response(raw, expected_input, payload["max_output_tokens"], STAGE_BOUNDS[stage_kind])
                return content
            value = client.strict_json(raw)
            require(isinstance(value, dict) and value.get("object") == "response.input_tokens"
                    and type(value.get("input_tokens")) is int and value["input_tokens"] > 0,
                    "count_invalid")
            operation["input_tokens"] = value["input_tokens"]
            return value["input_tokens"]
        except (Exception, KeyboardInterrupt) as error:
            self.fenced, self.failure = True, safe_failure(error, "request_failed")
            operation["failure"] = self.failure
            raise Error(self.failure) from None
        finally:
            operation["elapsed_seconds"] = time.monotonic() - started
            try:
                private_json(self.output / (name + "-receipt.json"), operation)
            except (Exception, KeyboardInterrupt):
                self.fenced, self.failure = True, "private_capture_failed"
                raise Error(self.failure) from None

    def count(self, messages):
        self._check()
        try:
            self._messages(messages)
            identity = client.digest(canonical(messages))
            if identity not in self.count_cache:
                payload = {"model": MODEL, "input": messages}
                self.count_cache[identity] = self._dispatch("count", payload)
            return self.count_cache[identity]
        except (Exception, KeyboardInterrupt) as error:
            self.fenced, self.failure = True, safe_failure(error, "count_failed")
            raise Error(self.failure) from None

    def generate(self, stage, messages, max_output_tokens):
        self._check()
        try:
            plan_match = PLAN_STAGE.fullmatch(stage) if isinstance(stage, str) else None
            stage_kind = "plan" if plan_match else stage
            require(stage_kind in STAGE_BOUNDS and (stage_kind != "plan" or plan_match
                    and int(plan_match.group(1)) <= self._limit("max_actions", 6))
                    and type(max_output_tokens) is int
                    and 0 < max_output_tokens <= STAGE_BOUNDS[stage_kind], "stage_output_limit_invalid")
            count = self.count(messages)
            require(count <= self._limit("input_tokens", 24576), "input_token_budget_exceeded")
            payload = client.payload_for("openai", messages)
            require(payload["model"] == MODEL, "model_identity_mismatch")
            payload["max_output_tokens"] = max_output_tokens
            return self._dispatch("generation", payload, expected_input=count, stage=stage)
        except (Exception, KeyboardInterrupt) as error:
            self.fenced, self.failure = True, safe_failure(error, "generation_failed")
            raise Error(self.failure) from None

    def cancelled(self):
        if not self.fenced and self.clock() - self.started >= self.maximum_elapsed:
            self.fenced, self.failure = True, "provider_admission_deadline_exceeded"
        return self.fenced

    def receipt(self):
        return {"count_calls": self.count_calls, "generation_calls": self.generation_calls,
                "http_calls": self.http_calls, "fenced": self.fenced, "failure": self.failure,
                "reserved_input_tokens": self.reserved_input, "reserved_output_tokens": self.reserved_output,
                "reserved_cost_usd": usd(self.reserved_cost), "maximum_cost_usd": usd(self.maximum_cost),
                "observed_input_tokens": self.observed_input, "observed_output_tokens": self.observed_output,
                "observed_cost_usd": usd(self.observed_cost),
                "unknown_generation_requests": sum(op["kind"] == "generation" and op["dispatched"]
                    and op["usage_status"] == "unknown" for op in self.operations)}


def read_key(path):
    raw = read_bytes(path, 16_384, "credential_read_failed")
    try:
        key = raw.decode().strip()
    except UnicodeError:
        raise Error("credential_format_invalid") from None
    if key.startswith("OPENAI_API_KEY="):
        key = key.split("=", 1)[1].strip().strip("\"'")
    require(key and "\n" not in key and "\r" not in key, "credential_format_invalid")
    return key


def run(args):
    if args.execute:
        require(args.api_key_file and args.max_cost_usd is not None, "execution_arguments_required")
        cost_cap_microusd(args.max_cost_usd)
    else:
        require(args.api_key_file is None, "credential_argument_requires_execution")
    declaration = prepare(args.input, args.output, args.max_cost_usd)
    if not args.execute:
        return {"status": "prepared", "provider_calls": 0, **declaration["counts"]}
    # There is intentionally no default credential path or automatic continuation.
    from history_navigation import NavigationHistory
    from memory_investigation import InvestigationLimits, MemoryInvestigation
    output = Path(args.output)
    provider = None
    engine = None
    history = None
    try:
        verify_prepared(output, declaration)
        key = read_key(args.api_key_file)
        provider = OpenAIProvider(output, key, declaration)
        case = validate_case(read_bytes(output / "case.json", MAXIMUM_INPUT_BYTES, "frozen_read_failed"))
        history = NavigationHistory(case["sources"])
        engine = MemoryInvestigation(history, provider, limits=InvestigationLimits(), cancelled=provider.cancelled)
        result = engine.run(case["question"], case["question_date"])
        verify_prepared(output, declaration)
        private_json(output / "result.json", result)
        summary = {"status": "completed", **provider.receipt()}
        private_json(output / "provider-summary.json", summary)
        return summary
    except (Exception, KeyboardInterrupt) as error:
        failure = safe_failure(error, "investigation_failed")
        if provider is not None:
            provider.fenced = True
            provider.failure = provider.failure or failure
        summary = {**(provider.receipt() if provider is not None else {"provider_calls": 0}),
                   "status": "failed", "failure": failure,
                   "engine_failure": failure if engine is not None else None,
                   "provider_failure": provider.failure if provider is not None else None}
        if engine is not None:
            engine.failed = True
            private_json(output / "engine-failure-receipt.json", {
                "count_calls": engine.count_calls, "generation_calls": engine.generation_calls,
                "reserved_input_tokens": engine.reserved_input, "reserved_output_tokens": engine.reserved_output,
                "failed": engine.failed, "model_receipts": engine.model_receipts})
        private_json(output / "provider-summary.json", summary)
        return summary
    finally:
        if history is not None:
            history.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="single case with question, question_date and sources only")
    parser.add_argument("--output", required=True, help="fresh absolute directory under .build/evaluation")
    parser.add_argument("--execute", action="store_true", help="explicit provider execution; requires authorization and spending cap")
    parser.add_argument("--api-key-file", help="credential file read only with --execute")
    parser.add_argument("--max-cost-usd", help="positive finite hard cap; required with --execute")
    args = parser.parse_args(argv)
    try:
        summary = run(args)
    except (Exception, KeyboardInterrupt) as error:
        summary = {"status": "failed", "failure": safe_failure(error, "preparation_failed"), "provider_calls": 0}
    print(json.dumps(summary, sort_keys=True), flush=True)
    return 0 if summary["status"] in ("prepared", "completed") else 1


if __name__ == "__main__":
    sys.exit(main())
