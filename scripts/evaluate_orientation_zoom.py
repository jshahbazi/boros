#!/usr/bin/env python3
"""Explicitly authorized, private standalone orientation/inspection pilot.

No production remote adapter or native selection change is enabled. Output is
metadata only. Original records and all model traffic remain in ignored files.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time

import evaluate_answerer_controls as client
import longmemeval_independent_cases as cohort
import local_longmemeval_qa as qa
import longmemeval_cases as original
import orientation_zoom as memory
import orientation_zoom_judging as judging

VERSION = "orientation-zoom-pilot-v1"
DOMAIN = "boros-orientation-zoom-development-v1"
ARMS = ("lexical_exchange", "inspection", "orientation_inspection")
SLOTS = ("abstention",) * 5 + tuple(t for t in qa.CASE_TYPES[:6] for _ in range(4)) + ("multi-session",)
CASE_IDS = tuple("0ddfec37_abs,29f2956b_abs,6aeb4375_abs,80ec1f4f_abs,ba358f49_abs,e493bb7c,184da446,0f05491a,9ea5eabc,8979f9ec,gpt4_ab202e7f,gpt4_59c863d7,5a7937c8,ceb54acb,f523d9fe,41275add,7a8d0b71,6b7dfb22,75832dbd,0edc2aef,1c0ddc50,ccb36322,36580ce8,577d4d32,f8c5f88b,gpt4_f420262d,2ebe6c90,gpt4_fa19884d,c8090214,6cb6f249".split(","))
CONFIG = {"model": client.OPENAI_MODEL, "reasoning_effort": "low", "maximum_tool_actions": 2,
          "recent_tokens": 8000, "evidence_tokens": 12000, "orientation_tokens": 8000,
          "foreground_input_tokens": 24576, "foreground_output_reserve": 8192,
          "visible_answer_tokens": 1024, "summary_input_tokens": 262000,
          "summary_output_reserve": 16384, "maximum_http_calls": 4096,
          "maximum_generation_calls": 510, "maximum_observed_input_tokens": 20000000,
          "maximum_observed_output_tokens": 1000000, "workers": 3,
          "added_memory_p95_target_seconds": 0.5, "added_episode_p95_target_ratio": 0.1}
DEPENDENCIES = ("evaluate_orientation_zoom.py", "orientation_zoom.py", "orientation_zoom_judging.py",
                "evaluate_answerer_controls.py", "longmemeval_independent_cases.py", "local_longmemeval_qa.py",
                "longmemeval_cases.py", "evaluate_longmemeval.py", "evaluate_answers.py", "evaluation_fixtures.py", "import_chat.py")
Error = client.DiagnosticError
require = client.require
canonical = client.canonical
digest = client.digest


def private_json(path, value):
    client.private_write(path, canonical(value))


def pins():
    here = Path(__file__).resolve().parent
    return {name: digest((here / name).read_bytes()) for name in DEPENDENCIES}


def select(rows):
    # The existing pure selector's configuration is restored before concurrency.
    previous = cohort.DOMAIN, cohort.SLOTS, cohort.EXCLUDED_CASE_IDS
    try:
        cohort.DOMAIN, cohort.SLOTS = DOMAIN, SLOTS
        cohort.EXCLUDED_CASE_IDS = qa.CASE_IDS + cohort.CASE_IDS
        ids, manifest = cohort.select_rows(rows)
    finally:
        cohort.DOMAIN, cohort.SLOTS, cohort.EXCLUDED_CASE_IDS = previous
    require(ids == CASE_IDS, "cohort_identity_mismatch")
    manifest.update(cohort=VERSION, declared_cases=30, declared_attempts=90)
    return ids, manifest


def prepare(source, output):
    raw = source.read_bytes()
    require(len(raw) == qa.SOURCE_BYTES and digest(raw) == qa.SOURCE_SHA256, "source_pin_mismatch")
    rows = client.strict_json(raw)
    require(isinstance(rows, list) and len(rows) == 500, "source_inventory_mismatch")
    ids, manifest = select(rows)
    indexed = {row["question_id"]: (i, row) for i, row in enumerate(rows)}
    inputs, scorers = [], []
    for qid in ids:
        original_index, row = indexed[qid]
        require(len(row["haystack_dates"]) == len(row["haystack_sessions"]) == len(row["haystack_session_ids"]), "history_inventory_invalid")
        records, labels = [], []
        for si, (sid, date, turns) in enumerate(zip(row["haystack_session_ids"], row["haystack_dates"], row["haystack_sessions"])):
            for ti, turn in enumerate(turns):
                require(turn["role"] in ("user", "assistant") and isinstance(turn["content"], str), "source_invalid")
                eid = f"{qid}-s{si:04d}-m{ti:04d}"
                records.append({"event_id": eid, "original_session_id": sid, "role": turn["role"], "status": "complete",
                    "session_index": si, "turn_index": ti, "content": turn["content"],
                    "source_time": {**original.normalize_time(date), "original_value": date, "source_sha256": qa.SOURCE_SHA256,
                                    "locator": f"/{original_index}/haystack_dates/{si}"}})
                if turn.get("has_answer") is True:
                    labels.append(eid)
        inputs.append({"question_id": qid, "question": row["question"], "question_date": row["question_date"], "sources": records})
        scorers.append({"question_id": qid, "question_type": row["question_type"], "reference": str(row["answer"]),
                        "abstention": qid.endswith("_abs"), "positive_ids": labels, "gold_sessions": row["answer_session_ids"]})
    output.mkdir(mode=0o700)
    private_json(output / "inputs.json", {"contains_oracle": False, "cases": inputs})
    private_json(output / "scorer.json", {"cases": scorers})
    declaration = {"version": VERSION, "configuration": CONFIG, "arms": list(ARMS), "source_sha256": qa.SOURCE_SHA256,
        "selection": manifest, "inputs_sha256": digest((output / "inputs.json").read_bytes()),
        "scorer_sha256": digest((output / "scorer.json").read_bytes()), "dependencies": pins(),
        "official_protocol_sha256": qa.PROTOCOL_SHA256, "standalone": True, "native_adapter": False,
        "baseline": "system_sqlite_fts5_bm25_complete_exchanges",
        "orientation_final_evidence": False,
        "summary_unit": "original_session", "summary_question_blind": True,
        "summary_max_characters": 240, "summary_source_ids": [1, 2],
        "scoring": "upstream_category_qa_plus_separate_source_only_sufficiency_and_claim_support",
        "unknown_or_failed_attempts_remain_in_denominator": True}
    private_json(output / "declaration.json", declaration)
    capture = output / "source-capture"
    capture.mkdir(mode=0o700)
    for name in declaration["dependencies"]:
        client.private_write(capture / name, (Path(__file__).resolve().parent / name).read_bytes())
    return declaration


def parse_response(raw, visible_limit):
    value = client.strict_json(raw)
    require(value.get("model") == client.OPENAI_MODEL and value.get("status") == "completed"
            and value.get("error") is None, "model_or_completion_invalid")
    usage = client.parse_usage("openai", value)
    parts = []
    for item in value.get("output", []):
        if item.get("type") == "reasoning":
            continue
        require(item.get("type") == "message" and item.get("role") == "assistant" and item.get("status") == "completed", "output_invalid")
        for part in item.get("content", []):
            require(part.get("type") == "output_text" and isinstance(part.get("text"), str), "refusal_or_output_invalid")
            parts.append(part["text"])
    text = "\n".join(parts)
    require(bool(text.strip()) and usage["nonreasoning_output_upper_bound"] <= visible_limit, "visible_output_invalid")
    return text, usage


class API:
    def __init__(self, output, key, declaration, protocol=None):
        self.output, self.key, self.declaration = output, key, declaration
        self.lock = threading.Lock()
        self.operations, self.counts = {}, {}
        self.generation_calls = self.http_calls = 0
        self.observed_input = self.observed_output = 0
        self.reserved_input = self.reserved_output = 0
        self.protocol = protocol

    def frozen(self):
        require(pins() == self.declaration["dependencies"], "implementation_changed")
        require(digest((self.output / "inputs.json").read_bytes()) == self.declaration["inputs_sha256"] and
                digest((self.output / "scorer.json").read_bytes()) == self.declaration["scorer_sha256"] and
                (self.output / "declaration.json").read_bytes() == canonical(self.declaration), "frozen_artifact_changed")
        if self.protocol is not None:
            require(digest(self.protocol.read_bytes()) == self.declaration["official_protocol_sha256"], "protocol_changed")

    def request(self, name, kind, payload, reserved_input=0):
        self.frozen()
        with self.lock:
            require(name not in self.operations and self.http_calls < CONFIG["maximum_http_calls"], "request_identity_or_budget_invalid")
            if kind == "generation":
                require(self.generation_calls < CONFIG["maximum_generation_calls"] and
                        self.reserved_input + reserved_input <= CONFIG["maximum_observed_input_tokens"] and
                        self.reserved_output + payload["max_output_tokens"] <= CONFIG["maximum_observed_output_tokens"], "generation_budget_exhausted")
                self.generation_calls += 1
                self.reserved_input += reserved_input
                self.reserved_output += payload["max_output_tokens"]
            self.http_calls += 1
            self.operations[name] = {"name": name, "kind": kind, "prepared": True, "dispatched": False, "received": False}
        client.private_write(self.output / (name + "-request.json"), canonical(payload))
        operation = self.operations[name]
        operation["request_sha256"] = digest(canonical(payload))
        start = time.monotonic()
        try:
            endpoint = "https://api.openai.com/v1/responses" + ("/input_tokens" if kind == "count" else "")
            operation["dispatched"] = True
            raw = client.http(endpoint, payload, self.key)
            client.private_write(self.output / (name + "-response.json"), raw)
            operation.update(received=True, response_sha256=digest(raw))
            if kind == "generation":
                try:
                    usage = client.parse_usage("openai", client.strict_json(raw))
                    operation["usage"] = usage
                    with self.lock:
                        self.observed_input += usage["input_tokens"]
                        self.observed_output += usage["output_tokens"]
                        self.reserved_input += usage["input_tokens"] - reserved_input
                        self.reserved_output += usage["output_tokens"] - payload["max_output_tokens"]
                except Error:
                    operation["usage_unknown"] = True
            self.frozen()
            return raw
        except Error as error:
            operation["failure"] = str(error)
            raise
        except Exception:
            operation["failure"] = "capture_failed"
            raise Error("capture_failed") from None
        finally:
            operation["elapsed_seconds"] = time.monotonic() - start
            private_json(self.output / (name + "-operation.json"), operation)

    def count(self, messages, name):
        body = {"model": client.OPENAI_MODEL, "input": messages}
        identity = digest(canonical(body))
        with self.lock:
            known = self.counts.get(identity)
        if known is not None:
            return known
        value = client.strict_json(self.request(name + "-count", "count", body))
        result = value.get("input_tokens")
        require(value.get("object") == "response.input_tokens" and type(result) is int and result > 0, "count_invalid")
        with self.lock:
            self.counts[identity] = result
        return result

    def call(self, messages, name, summary=False):
        count = self.count(messages, name)
        limit = CONFIG["summary_input_tokens"] if summary else CONFIG["foreground_input_tokens"]
        require(count <= limit, "input_budget_exceeded")
        payload = client.payload_for("openai", messages)
        payload["max_output_tokens"] = CONFIG["summary_output_reserve"] if summary else CONFIG["foreground_output_reserve"]
        text, usage = parse_response(self.request(name, "generation", payload, reserved_input=count), 16384 if summary else 1024)
        require(usage["input_tokens"] == count, "input_count_mismatch")
        return text, usage


def counted_pack(api, history, pack, cap, name):
    result = pack["evidence"]
    priority = list(pack["accepted_block_ids"])
    ordinal = 0
    while result:
        n = api.count([{"role": "user", "content": canonical(result).decode()}], f"{name}-{ordinal}")
        if n <= cap:
            return result, n
        # Keep ranking priority while dropping complete lowest-priority units.
        priority.pop()
        result = history.pack_blocks(priority, maximum_bytes=48000)["evidence"]
        ordinal += 1
    return [], 0


def planner_messages(api, history, case, recent, evidence, overview, traces, name):
    selected_recent = list(recent)
    selected_evidence = list(evidence)
    ordinal = 0
    while True:
        messages = history.action_messages(case["question"], case["question_date"],
            history.union(selected_recent, selected_evidence), orientation=overview, tool_results=traces)
        count = api.count(messages, f"{name}-admit-{ordinal}")
        if count <= CONFIG["foreground_input_tokens"]:
            return messages
        rows = selected_recent if selected_recent else selected_evidence
        require(bool(rows), "planner_input_budget_exceeded")
        # Recent is chronological; oldest first. Evidence is only reduced here
        # for planner visibility; final source selection stays separately bound.
        remove = set(history.block_source_ids(rows[0]["event_id"]))
        rows[:] = [row for row in rows if row["event_id"] not in remove]
        ordinal += 1


def recall(records, scorer):
    ids = {record["event_id"] for record in records}
    sessions = {record["original_session_id"] for record in records}
    return {"positive_turns": len(scorer["positive_ids"]), "full_positive_turns_delivered": len(ids.intersection(scorer["positive_ids"])),
            "gold_sessions": len(scorer["gold_sessions"]), "gold_sessions_delivered": len(sessions.intersection(scorer["gold_sessions"]))}


def p95(values):
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * .95
    left = int(position)
    return values[left] + (values[min(left + 1, len(values) - 1)] - values[left]) * (position - left)


def execute_case(api, case, scorer, protocol):
    qid = case["question_id"]
    history = memory.History(case["sources"])
    overview, summary_failure = None, None
    summary_start = time.monotonic()
    try:
        text, _usage = api.call(history.orientation_messages(), qid + "-orientation", summary=True)
        parsed = history.parse_orientation(text)
        overview, manifest = parsed["orientation"], parsed["receipt"]
        view_tokens = api.count([{"role": "user", "content": canonical(overview).decode()}], qid + "-view")
        require(view_tokens <= CONFIG["orientation_tokens"], "orientation_budget_exceeded")
        private_json(api.output / (qid + "-orientation-manifest.json"), manifest)
    except Exception as error:
        summary_failure = str(error) if isinstance(error, (Error, memory.ExperimentError)) else "orientation_failed"
    summary_seconds = time.monotonic() - summary_start
    baseline_start = time.monotonic()
    recent_pack = history.recent(maximum_bytes=32000)
    recent, recent_tokens = counted_pack(api, history, recent_pack, CONFIG["recent_tokens"], qid + "-recent")
    baseline_pack = history.baseline(case["question"], maximum_bytes=48000, excluded_ids=[r["event_id"] for r in recent])
    private_json(api.output / (qid + "-baseline-selection.json"), baseline_pack)
    baseline, _ = counted_pack(api, history, baseline_pack, CONFIG["evidence_tokens"], qid + "-baseline-pack")
    baseline_seconds = time.monotonic() - baseline_start
    results = []
    sufficiency_cache = {}
    # Deterministic alternating order mitigates a systematic arm/time ordering.
    arms = ARMS if int(digest(qid.encode())[-1], 16) % 2 == 0 else tuple(reversed(ARMS))
    for arm in arms:
        start = time.monotonic()
        evidence, traces = list(baseline), []
        result = {"case": qid, "arm": arm, "operational_complete": False, "qa": "unknown",
                  "sufficiency": "unknown", "support": "unknown", "citation_support": "unknown",
                  "tool_actions": 0, "positive_turns": len(scorer["positive_ids"]), "gold_sessions": len(scorer["gold_sessions"]),
                  "full_positive_turns_delivered": 0, "gold_sessions_delivered": 0,
                  "summary_failure": summary_failure if arm == "orientation_inspection" else None}
        try:
            if arm == "orientation_inspection":
                require(overview is not None, "orientation_unavailable")
            if arm != "lexical_exchange":
                for step in range(CONFIG["maximum_tool_actions"]):
                    messages = planner_messages(api, history, case, recent, evidence,
                        overview if arm == "orientation_inspection" else None, traces, f"{qid}-{arm}-plan-{step}")
                    text, _ = api.call(messages, f"{qid}-{arm}-plan-{step}")
                    action = memory.parse_action(text)
                    if action["action"] == "finish":
                        break
                    tool = history.execute(action, evidence, maximum_bytes=48000, excluded_ids=[r["event_id"] for r in recent])
                    evidence = tool["evidence"]
                    traces.append(tool["tool_result"])
                    result["tool_actions"] += 1
                    private_json(api.output / f"{qid}-{arm}-tool-{step}.json", tool)
                    evidence, _ = counted_pack(api, history, tool, CONFIG["evidence_tokens"], f"{qid}-{arm}-pack-{step}")
            final_pack = {"evidence": evidence, "accepted_block_ids": list(dict.fromkeys(history.event_block[r["event_id"]] for r in evidence))}
            evidence, evidence_tokens = counted_pack(api, history, final_pack, CONFIG["evidence_tokens"], f"{qid}-{arm}-final-pack")
            delivered = history.union(recent, evidence)
            messages = history.final_messages(case["question"], case["question_date"], delivered)
            input_tokens = api.count(messages, f"{qid}-{arm}-final")
            require(input_tokens <= CONFIG["foreground_input_tokens"], "final_input_budget_exceeded")
            pack_sha = digest(canonical(delivered))
            private_json(api.output / f"{qid}-{arm}-pack.json", {"records": delivered, "sha256": pack_sha,
                "recent_tokens": recent_tokens, "evidence_tokens": evidence_tokens, "input_tokens": input_tokens})
            result.update(pack_sha256=pack_sha, delivered_sources=len(delivered), recent_tokens=recent_tokens,
                          evidence_tokens=evidence_tokens, input_tokens=input_tokens, **recall(delivered, scorer))
            result["memory_seconds"] = baseline_seconds + time.monotonic() - start
            # Source-only sufficiency is frozen before the candidate is created.
            try:
                if pack_sha not in sufficiency_cache:
                    # Freeze an unknown before dispatch so a failed assessment
                    # is retained rather than implicitly retried by another arm.
                    sufficiency_cache[pack_sha] = "unknown"
                    text, _ = api.call(judging.sufficiency_messages(case["question"], case["question_date"], scorer["reference"], delivered),
                                       f"{qid}-{arm}-sufficiency")
                    sufficiency_cache[pack_sha] = judging.parse_sufficiency(text)["sufficient"]
                result["sufficiency"] = sufficiency_cache[pack_sha]
            except Exception:
                result["sufficiency_failure"] = "assessment_unknown"
            text, usage = api.call(messages, f"{qid}-{arm}-answer")
            client.private_write(api.output / f"{qid}-{arm}-answer.txt", text.encode())
            result.update(operational_complete=True, answer_sha256=digest(text.encode()), answer_bytes=len(text.encode()), answer_usage=usage)
            result["answer_episode_seconds_excluding_diagnostic_judges"] = result["memory_seconds"] + api.operations[f"{qid}-{arm}-answer"]["elapsed_seconds"]
            try:
                check, _ = api.call(judging.official_qa_messages(scorer["question_type"], case["question"], scorer["reference"], text,
                    scorer["abstention"], protocol_path=protocol), f"{qid}-{arm}-qa")
                result["qa"] = judging.parse_official_qa(check)["correct"]
            except Exception:
                result["qa_failure"] = "assessment_unknown"
            try:
                check, _ = api.call(judging.support_messages(case["question"], case["question_date"], text, delivered), f"{qid}-{arm}-support")
                support = judging.parse_support(check)
                result["support"], result["citation_support"] = support["all_claims_supported"], support["citations_supported"]
            except Exception:
                result["support_failure"] = "assessment_unknown"
        except Exception as error:
            result["failure"] = str(error) if isinstance(error, (Error, memory.ExperimentError)) else "attempt_failed"
        result["elapsed_seconds_with_diagnostic_judges"] = time.monotonic() - start
        result["summary_creation_seconds"] = summary_seconds if arm == "orientation_inspection" else 0
        private_json(api.output / f"{qid}-{arm}-result.json", result)
        results.append(result)
    print(json.dumps({"case_complete": qid, "arms_complete": sum(r["operational_complete"] for r in results)}), flush=True)
    history.close()
    return results


def report(api, results):
    summaries = {}
    for arm in ARMS:
        rows = [r for r in results if r["arm"] == arm]
        summaries[arm] = {"declared": 30, "operational_complete": sum(r["operational_complete"] for r in rows),
            "qa_yes": sum(r["qa"] == "yes" for r in rows), "qa_no": sum(r["qa"] == "no" for r in rows),
            "qa_unknown": sum(r["qa"] == "unknown" for r in rows),
            "supported_qa_yes": sum(r["qa"] == "yes" and r["support"] == "yes" and r["citation_support"] == "yes" for r in rows),
            "sufficient_yes": sum(r["sufficiency"] == "yes" for r in rows),
            "tool_actions": sum(r["tool_actions"] for r in rows),
            "positive_turns": sum(r.get("positive_turns", 0) for r in rows),
            "full_positive_turns_delivered": sum(r.get("full_positive_turns_delivered", 0) for r in rows),
            "memory_p95_seconds": p95([r["memory_seconds"] for r in rows if "memory_seconds" in r]),
            "episode_p95_seconds_excluding_judges": p95([r["answer_episode_seconds_excluding_diagnostic_judges"] for r in rows if "answer_episode_seconds_excluding_diagnostic_judges" in r]),
            "summary_creation_p95_seconds": p95([r["summary_creation_seconds"] for r in rows if "summary_creation_seconds" in r])}
    pairs = {}
    by_key = {(r["case"], r["arm"]): r for r in results}
    for arm in ARMS[1:]:
        pairs[arm] = {"wins": 0, "losses": 0, "both_yes": 0, "both_not_yes": 0}
        for qid in CASE_IDS:
            base, candidate = by_key[qid, ARMS[0]]["qa"] == "yes", by_key[qid, arm]["qa"] == "yes"
            pairs[arm]["wins" if candidate and not base else "losses" if base and not candidate else "both_yes" if base else "both_not_yes"] += 1
    usage = {k: sum(op.get("usage", {}).get(k, 0) for op in api.operations.values()) for k in
             ("input_tokens", "output_tokens", "reasoning_tokens", "cached_input_tokens")}
    return {"version": VERSION, "status": "terminal", "declaration_sha256": digest((api.output / "declaration.json").read_bytes()),
        "summaries": summaries, "paired_qa": pairs, "attempts": results, "operations": api.operations,
        "usage": usage, "observed_receipt_standard_generation_cost_estimate_usd": (2 * usage["input_tokens"] + 10 * usage["output_tokens"]) / 1000000,
        "held_input_tokens_including_unknown": api.reserved_input, "held_output_tokens_including_unknown": api.reserved_output,
        "unknown_generation_receipts": sum(op["kind"] == "generation" and "usage" not in op for op in api.operations.values()),
        "http_calls": api.http_calls, "generation_calls": api.generation_calls,
        "native_application_measured": False, "representative_accuracy_established": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--api-key-file", type=Path)
    parser.add_argument("--protocol", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    private_root = Path(__file__).resolve().parents[1] / ".build" / "evaluation"
    require(args.output.is_absolute() and not args.output.is_symlink() and args.output.resolve().is_relative_to(private_root.resolve()), "output_path_refused")
    require(digest(args.protocol.read_bytes()) == qa.PROTOCOL_SHA256, "protocol_pin_mismatch")
    declaration = prepare(args.source, args.output)
    print(json.dumps({"prepared": 30, "declared_attempts": 90, "declaration_sha256": digest(canonical(declaration))}), flush=True)
    if not args.execute:
        return
    require(args.api_key_file is not None, "credential_missing")
    key = args.api_key_file.read_text().strip()
    if key.startswith("OPENAI_API_KEY="):
        key = key.split("=", 1)[1].strip().strip("\"'")
    require(bool(key) and "\n" not in key and "\r" not in key, "credential_invalid")
    api = API(args.output, key, declaration, args.protocol)
    cases = client.strict_json((args.output / "inputs.json").read_bytes())["cases"]
    scorers = {r["question_id"]: r for r in client.strict_json((args.output / "scorer.json").read_bytes())["cases"]}
    results = []
    with ThreadPoolExecutor(max_workers=CONFIG["workers"]) as workers:
        futures = {workers.submit(execute_case, api, case, scorers[case["question_id"]], args.protocol): case["question_id"] for case in cases}
        for future in as_completed(futures):
            qid = futures[future]
            try:
                results.extend(future.result())
            except Exception:
                for arm in ARMS:
                    existing = args.output / f"{qid}-{arm}-result.json"
                    if existing.exists():
                        results.append(client.strict_json(existing.read_bytes()))
                        continue
                    result = {"case": qid, "arm": arm, "operational_complete": False, "qa": "unknown", "sufficiency": "unknown",
                              "support": "unknown", "citation_support": "unknown", "tool_actions": 0, "failure": "case_failed",
                              "positive_turns": len(scorers[qid]["positive_ids"]), "gold_sessions": len(scorers[qid]["gold_sessions"]),
                              "full_positive_turns_delivered": 0, "gold_sessions_delivered": 0}
                    private_json(api.output / f"{qid}-{arm}-result.json", result)
                    results.append(result)
    api.frozen()
    final = report(api, sorted(results, key=lambda r: (CASE_IDS.index(r["case"]), ARMS.index(r["arm"]))))
    private_json(args.output / "report.json", final)
    print(json.dumps({"terminal": True, "summary": final["summaries"], "http_calls": api.http_calls,
                      "generation_calls": api.generation_calls, "report_sha256": digest(canonical(final))}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"failure": str(error) if isinstance(error, Error) else "pilot_failed"}), flush=True)
        sys.exit(1)
