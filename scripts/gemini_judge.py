#!/usr/bin/env python3
"""Gemini 3.8 Flash as a second verdict judge, to check the default judge for self-preference.

The default judge (Vertex Sonnet 5.5) graded Sonnet- and Haiku-authored answers in the reader
comparison (docs/READER-COMPARISON.md). This runner grades the same blinded items with a judge from
another model family, and first grades the 79 calibration items so that its own error rates against
the user's reference adjudication are known.

The judge request is the default judge's: prompt set v3, verdict task only, rendered by
``judge_calibration.judge_messages`` with the reply-format system line (instructed JSON) and parsed by
``judge_calibration.parse_instructed_reply``. Only the model and its controls differ: Gemini through
``vertex_gemini.py``, thinking level "low" (its lowest; it cannot be turned off), no sampling field,
and an output limit that leaves room for thought tokens, which count against it.

Commands: ``declare`` freezes the sets, prompts, settings, replicates and cap; ``run`` dispatches
under the declaration (resumable) and writes one labels file per set in the judge_calibration
labels format, judge name ``vertex-gemini``.

Privacy: requests, replies and labels stay in the private output directory. stdout carries counts,
hashes, item IDs and fixed codes only.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal
import json
import math
import os
from pathlib import Path
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge_calibration as jc  # noqa: E402
import judge_calibration_run as jcr  # noqa: E402
import vertex_anthropic as va  # noqa: E402
import vertex_gemini as vg  # noqa: E402

VERSION = "gemini-judge-v1"
JUDGE = "vertex-gemini"
MODEL = "gemini-3.8-flash"
THINKING_LEVEL = "low"
MAX_OUTPUT_TOKENS = 2048
REPLICATES = 3
WORKERS = 6
INPUT_USD, OUTPUT_USD = "1.50", "7.50"
RETRYABLE = ("http_status_429", "http_status_500", "http_status_502", "http_status_503", "http_status_504",
             "transport_failed")
RETRY_DELAYS = (10, 30)


class JudgeError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise JudgeError(code)


def now():
    return datetime.now(timezone.utc).isoformat()


def private_directory(path: Path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def private_write(path: Path, data: bytes):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
    os.chmod(path, 0o600)


def messages_for(item, prompt_function):
    """The default judge's prompt set v3 verdict request: the upstream prompt plus the reply-format line."""
    return jc.judge_messages(item, "verdict", prompt_function, reply_instruction=True, verdict_rubric=False)


def estimated_input_tokens(messages):
    """A conservative reservation estimate (two characters per token); billing uses reported usage."""
    return math.ceil(sum(len(message["content"]) for message in messages) / 2) + 16


def label_from(raw):
    """(status, label, failure) as the default judge's runner records it: never coerced."""
    try:
        text, _usage = vg.parse_response(raw, MODEL)
    except va.VertexError as error:
        return "response_invalid", None, str(error)
    label = jc.parse_instructed_reply(text, "verdict")
    if label is None:
        return "parse_failed", None, "output_off_schema"
    return "completed", label, None


def declare(args):
    output = args.output.absolute()
    require(output.is_relative_to(jc.ROOT / ".build"), "output_outside_build")
    require(not (output / "declaration.json").exists(), "declaration_exists")
    prompt_function = jc.load_upstream_prompt_function(args.protocol)
    reference, _ = jcr.load_declaration(args.default_declaration)
    require(reference.get("judge") == "vertex-sonnet" and reference.get("format") == "boros-judge-calibration-vertex-declaration-v3",
            "default_declaration_not_v3")
    sets = []
    for set_dir in args.set:
        manifest, items = jcr.load_set(set_dir.absolute())
        rendered = [jc.canonical(messages_for(item, prompt_function)) for item in items]
        sets.append({"path": str(set_dir.absolute()), "set_id": manifest["set_id"], "item_count": len(items),
                     "items_sha256": manifest["items_sha256"],
                     "rendered_messages_sha256": jc.sha256_bytes(jc.canonical([jc.sha256_bytes(raw) for raw in rendered])),
                     "characters_max": max(len(raw) for raw in rendered)})
    requests = sum(entry["item_count"] for entry in sets) * REPLICATES
    declaration = {
        "version": VERSION, "declared_at_utc": now(), "judge": JUDGE,
        "authorization": "user, 2026-10-10, in chat: 'have Gemini judge them too to check self-preference'; the "
                         "coordinator declared the 79 calibration items first, then both reader-comparison halves, "
                         "three replicates, and a $12 cap",
        "provider": vg.configuration(MODEL, THINKING_LEVEL),
        "prompts": {**jcr.prompt_hashes(reference), "rendering": "judge_calibration.judge_messages(item, 'verdict', "
                    "prompt_function, reply_instruction=True, verdict_rubric=False), the default judge's v3 request"},
        "reply_format": jc.reply_format_declaration(),
        "execution": {"stages_per_item": ["verdict"], "replicates": REPLICATES, "vote": "majority of three; a tie or "
                      "fewer than two agreeing labels is unknown", "max_output_tokens_per_request": MAX_OUTPUT_TOKENS,
                      "thinking_level": THINKING_LEVEL, "sampling_parameters_sent": [], "workers": WORKERS,
                      "retry_rule": f"{list(RETRYABLE)} retried at most {len(RETRY_DELAYS)} times after "
                                    f"{list(RETRY_DELAYS)} seconds; other failures are recorded, never coerced"},
        "pricing": {**va.Pricing(INPUT_USD, OUTPUT_USD).declaration(),
                    "source": "list rate reported by third-party pricing pages, as declared for the reader comparison"},
        "budget": {"spending_cap_usd": str(args.cap), "max_generation_requests": requests,
                   "cap_rule": "before each dispatch, settled spend plus every in-flight request's reservation "
                               "(estimated input at two characters per token plus the full output limit) must "
                               "not exceed the cap"},
        "sets": sets, "order": "sets as listed (calibration first), then replicate, then item ID",
        "drivers": {name: jc.sha256_bytes((jc.ROOT / "scripts" / name).read_bytes())
                    for name in ("gemini_judge.py", "vertex_gemini.py", "judge_calibration.py")},
    }
    private_directory(output)
    private_write(output / "declaration.json", jc.canonical(declaration) + b"\n")
    private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"requests": requests, "sets": [[entry["set_id"], entry["item_count"]] for entry in sets],
                      "cap_usd": str(args.cap),
                      "declaration_sha256": jc.sha256_bytes((output / "declaration.json").read_bytes())}))


def run(args):
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    require(declaration.get("version") == VERSION, "declaration_version")
    for name, value in declaration["drivers"].items():
        require(jc.sha256_bytes((jc.ROOT / "scripts" / name).read_bytes()) == value, "driver_changed")
    prompt_function = jc.load_upstream_prompt_function(args.protocol)
    plan, bodies = [], {}
    for entry in declaration["sets"]:
        manifest, items = jcr.load_set(Path(entry["path"]))
        require(manifest["items_sha256"] == entry["items_sha256"], "set_changed")
        rendered = {item["item_id"]: messages_for(item, prompt_function) for item in items}
        require(jc.sha256_bytes(jc.canonical([jc.sha256_bytes(jc.canonical(rendered[item["item_id"]])) for item in items]))
                == entry["rendered_messages_sha256"], "rendering_changed")
        for item in items:
            messages = rendered[item["item_id"]]
            bodies[(entry["set_id"], item["item_id"])] = (vg.payload(messages, MAX_OUTPUT_TOKENS,
                                                                     thinking_level=THINKING_LEVEL),
                                                          estimated_input_tokens(messages))
        for replicate in range(1, REPLICATES + 1):
            for item in items:
                plan.append({"request_id": f"{entry['set_id']}:{item['item_id']}:r{replicate}", "set_id": entry["set_id"],
                             "item_id": item["item_id"], "replicate": replicate})
    require(len(plan) == declaration["budget"]["max_generation_requests"], "plan_size_changed")
    replies = output / "replies"
    private_directory(replies)
    done, spent = {}, 0
    for line in (output / "ledger.jsonl").read_text().splitlines():
        record = json.loads(line)
        if record["state"] == "finished" and record["status"] != "infrastructure":
            done[record["request_id"]] = record
            spent += record.get("microusd") or 0
    price = va.Pricing(declaration["pricing"]["input_usd_per_million_tokens"],
                       declaration["pricing"]["output_usd_per_million_tokens"])
    cap = Decimal(declaration["budget"]["spending_cap_usd"]) * 10**6
    lock = threading.Lock()
    state = {"spent": spent, "stopped": None}
    token = va.AccessTokens()
    url = vg.generation_url(MODEL)

    def append(record):
        with open(output / "ledger.jsonl", "a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

    def work(entry):
        body, estimate = bodies[(entry["set_id"], entry["item_id"])]
        worst = price.microusd(estimate, MAX_OUTPUT_TOKENS)
        with lock:
            if state["stopped"] or state["spent"] + worst > cap:
                state["stopped"] = state["stopped"] or "cap_reached"
                return
            state["spent"] += worst
            append({"request_id": entry["request_id"], "state": "started", "at": now()})
        tries, raw, failure = 0, None, None
        while True:
            tries += 1
            try:
                raw, failure = vg.post(url, body, token()), None
            except va.VertexError as error:
                raw, failure = None, str(error)
            if failure in RETRYABLE and tries <= len(RETRY_DELAYS):
                time.sleep(RETRY_DELAYS[tries - 1])
                continue
            break
        record = {**entry, "state": "finished", "tries": tries, "at": now()}
        microusd = 0
        if raw is None:
            record.update(status="infrastructure", failure=failure)
        else:
            private_write(replies / (entry["request_id"].replace(":", "--") + ".json"), raw)
            status, label, failure = label_from(raw)
            metadata = vg.response_metadata(raw)
            try:
                usage = vg.parse_usage(va._strict_json(raw))
                microusd = price.microusd(usage["input_tokens"], usage["output_tokens"])
                record.update(input_tokens=usage["input_tokens"], output_tokens=usage["output_tokens"],
                              thought_tokens=usage["reasoning_tokens"])
            except va.VertexError:
                pass
            record.update(status=status, label=label, failure=failure, stop_reason=metadata["stop_reason"])
        record["microusd"] = microusd
        with lock:
            state["spent"] += microusd - worst
            append(record)
            if record["status"] == "infrastructure" and failure not in RETRYABLE:
                state["stopped"] = "infrastructure_" + str(failure)

    pending = [entry for entry in plan if entry["request_id"] not in done]
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(work, pending))
    latest = {}
    for line in (output / "ledger.jsonl").read_text().splitlines():
        record = json.loads(line)
        if record["state"] == "finished":
            latest[record["request_id"]] = record
    complete = all(entry["request_id"] in latest and latest[entry["request_id"]]["status"] != "infrastructure"
                   for entry in plan)
    declaration_sha = jc.sha256_bytes(jc.canonical(declaration))
    summary = {}
    for entry in declaration["sets"]:
        table = {}
        for request in (request for request in plan if request["set_id"] == entry["set_id"]):
            record = latest.get(request["request_id"]) or {}
            label = record.get("label") if record.get("status") == "completed" else None
            row = table.setdefault(request["item_id"], [{"verdict": None, "sufficiency": None} for _ in range(REPLICATES)])
            row[request["replicate"] - 1]["verdict"] = label
        document = {"format": jc.LABELS_FORMAT, "set_id": entry["set_id"], "items_sha256": entry["items_sha256"],
                    "judge": JUDGE, "runner_judge": JUDGE, "declaration_sha256": declaration_sha,
                    "prompts": declaration["prompts"], "replicates": REPLICATES, "complete": complete,
                    "reply_format": declaration["reply_format"], "labels": dict(sorted(table.items()))}
        private_write(output / f"labels-{entry['set_id']}.json", jc.canonical(document) + b"\n")
        records = [latest.get(request["request_id"]) or {} for request in plan if request["set_id"] == entry["set_id"]]
        summary[entry["set_id"]] = {status: sum(1 for record in records if record.get("status") == status)
                                    for status in ("completed", "parse_failed", "response_invalid", "infrastructure")}
    finished = list(latest.values())
    print(json.dumps({"complete": complete, "stopped": state["stopped"], "by_set": summary,
                      "spent_usd": str(Decimal(sum(record.get("microusd") or 0 for record in finished)) / 10**6),
                      "thought_tokens": sum(record.get("thought_tokens") or 0 for record in finished),
                      "failure_codes": sorted({record.get("failure") for record in finished if record.get("failure")})}))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("declare", "run"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--protocol", type=Path, default=jc.DEFAULT_PROTOCOL)
        if name == "declare":
            command.add_argument("--set", type=Path, action="append", required=True)
            command.add_argument("--default-declaration", type=Path, required=True,
                                 help="a filled default-judge (v3) declaration whose prompt hashes this run must match")
            command.add_argument("--cap", type=Decimal, required=True)
    args = parser.parse_args(argv)
    try:
        {"declare": declare, "run": run}[args.command](args)
    except (JudgeError, va.VertexError, jc.CalibrationError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
