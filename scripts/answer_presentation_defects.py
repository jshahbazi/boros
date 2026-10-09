#!/usr/bin/env python3
"""Answer presentation defect diagnostics: pattern counts over saved answers and the current envelope.

Commands:

- ``measure``: read saved answer captures (read only, through ``judge_calibration``'s
  collectors) and print, per run, arm and answerer family, how many answers show each
  presentation defect pattern and how many occurrences there are. With
  ``--calibration-set`` and ``--item``, also print per-item counts for selected
  calibration items, resolved through the private key to their raw saved answers.
- ``envelope``: render the selected-Qwen envelope for a synthetic two-turn conversation
  in both the V3 framing (context-source-snapshot-v3, header-led prior turns) and the
  current default V4 framing (context-source-snapshot-v4, host-quoted prior turns,
  citation labels), using the framing literals read from this checkout's Swift source,
  so the exact labels the model sees can be inspected without any model call.

The module also provides the per-answer detector used by
``answer_presentation_replay.py``: copied headers in either framing, fabricated event IDs,
citation labels and whether each resolves to a delivered source, plain declines, and a
simple reference-string check.

Privacy contract: stdout carries pattern names, counts, run/arm/model identifiers and
calibration item IDs only. Answer, question, evidence and history text never leave the
process. The ``envelope`` command prints only code literals and synthetic text.
This tool makes no network, model-server or remote call of any kind.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge_calibration as jc  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
TOOL_VERSION = "answer-presentation-defects-v2"
FRAMING_SOURCE = ROOT / "Sources/Boros/ContextSourceFraming.swift"
ASSEMBLER_SOURCE = ROOT / "Sources/Boros/ContextAssembler.swift"

# Exact host-authored envelope labels (ContextSourceFraming.swift, ContextAssembler.swift).
RECENT_HEADING = "Recent source metadata (host):"
ORIGINAL_LABEL = "Original message text:"
HISTORICAL_MARKERS = ("BEGIN HISTORICAL SOURCE", "END HISTORICAL SOURCE", "quoted_excerpt:",
                      "Historical source excerpts for reference:")
HISTORICAL_FIELDS = ("event_id", "conversation_id", "role", "capture_status", "captured_utc",
                     "source_created_utc", "source_time", "source_sha256", "excerpt_utf8_offset",
                     "source_total_bytes")
INCOMPLETE_NOTICE = "[Incomplete historical"
# V4 quoted framing (context-source-snapshot-v4).
QUOTED_HEADING = "Earlier conversation message ["
QUOTED_TEXT_LABEL = "quoted_text:"
RE_CITATION = re.compile(r"\[(E\d+(?:\s*(?:,|;|and)\s*E\d+)*)\]")
RE_LABEL = re.compile(r"E(\d+)")
PLAIN_DECLINES = ("does not show", "doesn't show", "do not show", "don't show", "does not contain", "doesn't contain",
                  "does not mention", "doesn't mention", "not mentioned", "isn't mentioned", "is not mentioned",
                  "no record of", "no information about", "there is no information", "not in the provided",
                  "not provided in", "i couldn't find", "i could not find", "i can't find", "i cannot find",
                  "don't see any", "do not see any", "does not include", "doesn't include")
# The clean-pack and orientation controls frame evidence as JSON records under this label.
CONTROLS_LABEL = "Original chat records"

RE_RECENT_JSON = re.compile(r'\{"capture_status":"[a-z_]+","(?:captured_utc|event_id)":')
RE_HEADER_HUMAN = re.compile(r'\{"capture_status":"[a-z_]+",[^\n]*"role":"human"')
RE_FIELD_LINE = re.compile(r"(?m)^\s*(?:" + "|".join(HISTORICAL_FIELDS) + r"):")
RE_EVENT_ID = re.compile(r"[A-Za-z0-9_]+-s\d{4}-m\d{4}")
RE_EVENT_WORD = re.compile(r"(?i)\bevent[_ ]ids?\b")
RE_HEX64 = re.compile(r"\b[0-9a-f]{64}\b")
RE_INLINE_MATH = re.compile(r"(?<![\\$])\$(?=\S)[^$\n]{1,200}?(?<=\S)\$(?![\d$])")
RE_DISPLAY_MATH = re.compile(r"\$\$|\\\[|\\\]|\\\(|\\\)")
RE_LATEX_COMMAND = re.compile(r"\\(?:frac|times|text|cdot|approx|leq?|geq?|div|sqrt|boxed|quad|mathrm|mathbf|pm|"
                              r"rightarrow|to|%|\$)(?![A-Za-z])")
RE_CURRENCY = re.compile(r"(?<!\\)\$\d")
RE_BOLD = re.compile(r"\*\*[^*\n]+\*\*")
RE_HEADING = re.compile(r"(?m)^#{1,6}\s")
RE_LIST_ITEM = re.compile(r"(?m)^\s*(?:[*+-]|\d+\.)\s+")
RE_TABLE_ROW = re.compile(r"(?m)^\s*\|.*\|\s*$")
RE_ROLE_LINE = re.compile(r"(?mi)^\s*(?:\*\*)?(?:user|assistant|human|system|ai)(?:\*\*)?\s*:")
RE_QUESTION_LABEL = re.compile(r"(?mi)^\s*(?:question date|question)\s*:")
TEMPLATE_TOKENS = ("<|im_start|>", "<|im_end|>", "<|endoftext|>")
THINK_TAGS = ("<think>", "</think>")
SCAFFOLD_PHRASES = ("thinking process", "thought process:", "let me think", "let's think step by step",
                    "okay, so the user", "the user is asking", "the user asks", "the user wants")
DISCLAIMERS = ("as an ai", "as a language model", "i'm an ai", "i am an ai", "i don't have personal",
               "i do not have personal", "i don't have access to your", "i do not have access to your",
               "i don't have memory", "i do not have memory", "i don't have the ability to remember",
               "i do not have the ability to remember")
META_PHRASES = ("historical source", "source excerpt", "excerpts", "recent messages", "host metadata",
                "source metadata", "provided context", "the context provided", "supplied records",
                "chat records", "original records", "conversation history provided", "the records")

# Defect pattern -> (category, description). Categories group the user's notes.
PATTERNS = {
    "envelope_recent_heading": ("envelope", "the recent-message metadata heading"),
    "envelope_original_text_label": ("envelope", "the 'Original message text:' label"),
    "envelope_recent_metadata_json": ("envelope", "a recent-message metadata JSON object"),
    "envelope_header_at_answer_start": ("envelope", "the answer opens with the recent-message header"),
    "envelope_header_role_human": ("envelope", "an echoed header that names the human role"),
    "envelope_historical_markers": ("envelope", "historical-source block markers"),
    "envelope_historical_field_lines": ("envelope", "historical-source field lines such as 'event_id:'"),
    "envelope_incomplete_notice": ("envelope", "the incomplete-capture notice"),
    "envelope_controls_label": ("envelope", "the clean-pack 'Original chat records' label"),
    "quoted_source_heading": ("envelope", "the V4 quoted recent-source heading"),
    "quoted_text_label": ("envelope", "the V4 'quoted_text:' label"),
    "host_header_at_answer_start": ("envelope", "the answer opens with a V3 or V4 host source header or block marker"),
    "citation_label": ("identifier", "a cited host label such as [E2]"),
    "id_event_id_raw": ("identifier", "a raw benchmark event ID"),
    "id_event_id_word": ("identifier", "the words 'event ID' or 'event_id'"),
    "id_sha256_hex": ("identifier", "a 64-character hex digest"),
    "math_inline_dollar_pair": ("latex", "inline $...$ math"),
    "math_display_or_paren": ("latex", "$$, \\[ \\] or \\( \\) math delimiters"),
    "math_latex_command": ("latex", "a LaTeX command such as \\times or \\text"),
    "dollar_any": ("latex", "any dollar sign"),
    "dollar_currency": ("latex", "a dollar sign directly before a digit"),
    "markdown_bold": ("markdown", "**bold** spans"),
    "markdown_heading": ("markdown", "# headings"),
    "markdown_list_item": ("markdown", "list items"),
    "markdown_table_row": ("markdown", "table rows"),
    "role_label_line": ("role", "a line starting with a role label"),
    "template_token": ("scaffold", "chat-template control tokens"),
    "thinking_tag": ("scaffold", "<think> tags"),
    "thinking_scaffold_phrase": ("scaffold", "reasoning scaffold phrases"),
    "question_label_echo": ("question", "a 'Question:' or 'Question Date:' line"),
    "question_verbatim": ("question", "the question text verbatim"),
    "ends_with_question": ("question", "the answer ends with a question mark"),
    "ai_disclaimer": ("prose", "an 'as an AI' style disclaimer"),
    "plain_decline": ("prose", "a plain statement that the provided history does not show or contain it"),
    "meta_context_reference": ("prose", "talk about the supplied context or excerpts"),
}


def _normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()


def pattern_counts(answer: str, question: str | None = None) -> dict:
    """Occurrence count per pattern. Booleans count as 0 or 1."""
    lower = answer.lower()
    stripped = answer.lstrip()
    counts = {
        "envelope_recent_heading": answer.count(RECENT_HEADING),
        "envelope_original_text_label": answer.count(ORIGINAL_LABEL),
        "envelope_recent_metadata_json": len(RE_RECENT_JSON.findall(answer)),
        "envelope_header_at_answer_start": int(stripped.startswith(RECENT_HEADING)),
        "envelope_header_role_human": len(RE_HEADER_HUMAN.findall(answer)),
        "envelope_historical_markers": sum(answer.count(marker) for marker in HISTORICAL_MARKERS),
        "envelope_historical_field_lines": len(RE_FIELD_LINE.findall(answer)),
        "envelope_incomplete_notice": answer.count(INCOMPLETE_NOTICE),
        "envelope_controls_label": answer.count(CONTROLS_LABEL),
        "quoted_source_heading": answer.count(QUOTED_HEADING),
        "quoted_text_label": answer.count(QUOTED_TEXT_LABEL),
        "host_header_at_answer_start": int(stripped.startswith((RECENT_HEADING, QUOTED_HEADING, INCOMPLETE_NOTICE,
                                                                 "BEGIN HISTORICAL SOURCE", "Historical source excerpts"))),
        "citation_label": len(cited_labels(answer)),
        "id_event_id_raw": len(RE_EVENT_ID.findall(answer)),
        "id_event_id_word": len(RE_EVENT_WORD.findall(answer)),
        "id_sha256_hex": len(RE_HEX64.findall(answer)),
        "math_inline_dollar_pair": len(RE_INLINE_MATH.findall(answer)),
        "math_display_or_paren": len(RE_DISPLAY_MATH.findall(answer)),
        "math_latex_command": len(RE_LATEX_COMMAND.findall(answer)),
        "dollar_any": answer.count("$"),
        "dollar_currency": len(RE_CURRENCY.findall(answer)),
        "markdown_bold": len(RE_BOLD.findall(answer)),
        "markdown_heading": len(RE_HEADING.findall(answer)),
        "markdown_list_item": len(RE_LIST_ITEM.findall(answer)),
        "markdown_table_row": len(RE_TABLE_ROW.findall(answer)),
        "role_label_line": len(RE_ROLE_LINE.findall(answer)),
        "template_token": sum(answer.count(token) for token in TEMPLATE_TOKENS),
        "thinking_tag": sum(answer.count(tag) for tag in THINK_TAGS),
        "thinking_scaffold_phrase": sum(lower.count(phrase) for phrase in SCAFFOLD_PHRASES),
        "question_label_echo": len(RE_QUESTION_LABEL.findall(answer)),
        "question_verbatim": 0,
        "ends_with_question": int(answer.rstrip().endswith("?")),
        "ai_disclaimer": sum(lower.count(phrase) for phrase in DISCLAIMERS),
        "plain_decline": sum(lower.replace("\u2019", "'").count(phrase) for phrase in PLAIN_DECLINES),
        "meta_context_reference": sum(lower.count(phrase) for phrase in META_PHRASES),
    }
    if question:
        target = _normalized(question).rstrip("?").strip()
        if len(target) >= 15 and target in _normalized(answer):
            counts["question_verbatim"] = 1
    assert set(counts) == set(PATTERNS)
    return counts


def cited_labels(answer: str) -> list:
    """Every host label cited in square brackets, in order, e.g. [E2] or [E1, E3]."""
    return ["E" + number for group in RE_CITATION.findall(answer) for number in RE_LABEL.findall(group)]


def citation_resolution(answer: str, label_map) -> dict:
    """Counts of cited labels that resolve to a delivered source in the recorded label map."""
    delivered = {entry["label"] for entry in label_map or []}
    labels = cited_labels(answer)
    return {"cited_labels": len(labels), "distinct_cited_labels": len(set(labels)),
            "resolved_labels": sum(label in delivered for label in labels),
            "unresolved_labels": sum(label not in delivered for label in labels)}


def event_id_mentions(answer: str, known_ids) -> dict:
    """Raw benchmark event IDs in the answer and how many are absent from the history (fabricated)."""
    known = set(known_ids)
    found = RE_EVENT_ID.findall(answer)
    echoed = []
    for match in re.finditer(r'"event_id"\s*:\s*"([^"\n]{1,256})"', answer):
        echoed.append(match.group(1))
    fabricated = [value for value in found + echoed if value not in known]
    return {"raw_event_ids": len(found), "fabricated_event_ids": len(set(fabricated))}


def _plain(text) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^0-9a-z]+", " ", str(text).lower())).strip()


def contains_reference(answer: str, reference) -> bool:
    """Simple string check: the normalized reference occurs in the normalized answer."""
    target = _plain(reference)
    return bool(target) and target in _plain(answer)


def addresses_question(answer: str, question: str, counts: dict) -> bool:
    """Structural check: a non-empty answer that does not open with a host header and does
    not restate the question verbatim. It does not judge correctness."""
    return bool(answer.strip()) and not counts["host_header_at_answer_start"] and not counts["envelope_header_at_answer_start"] \
        and not counts["question_verbatim"]


def context_flags(evidence) -> dict:
    """Content-free facts about the delivered context, used only for cross-tabulation."""
    texts = [entry.get("text") or "" for entry in evidence or []]
    return {"context_inline_math": any(RE_INLINE_MATH.search(text) for text in texts),
            "context_markdown_bold": any(RE_BOLD.search(text) for text in texts)}


def new_group():
    return {"answers": 0, "answers_with": Counter(), "occurrences": Counter(), "answers_with_any": Counter()}


def add(group, counts):
    group["answers"] += 1
    categories = set()
    for name, value in counts.items():
        if value:
            group["answers_with"][name] += 1
            group["occurrences"][name] += value
            categories.add(PATTERNS[name][0])
    for category in categories:
        group["answers_with_any"][category] += 1


def finish(group):
    return {"answers": group["answers"], "answers_with": dict(sorted(group["answers_with"].items())),
            "occurrences": dict(sorted(group["occurrences"].items())),
            "answers_with_any_category": dict(sorted(group["answers_with_any"].items()))}


def recent_sources(roots):
    """Map native LongMemEval candidate keys to their delivered whole recent source IDs, in order."""
    out = {}
    for run, report_name, _, _ in jc.NATIVE_LONGMEMEVAL_RUNS:
        report_path = jc.find_root(roots, report_name)
        if report_path is None:
            continue
        report = jc.load_json(report_path)
        for history in report["histories"]:
            for attempt in history["attempts"]:
                ids = (attempt.get("metadata") or {}).get("delivered_recent_source_ids") or []
                out[f"{run}/{attempt['question_id']}/{attempt['strategy']}"] = list(ids)
    return out


RE_ECHO = re.compile(r"\s*" + re.escape(RECENT_HEADING) + r" (\{[^\n]*\})\n" + re.escape(ORIGINAL_LABEL) + r"\n")


def echo_provenance(candidate, recent_ids, dataset, stats):
    """Content-free facts about an answer-initial echoed recent header. Updates ``stats``."""
    match = RE_ECHO.match(candidate["answer_text"])
    if not match:
        return
    stats["echoed_headers"] += 1
    try:
        metadata = json.loads(match.group(1))
    except ValueError:
        stats["echo_json_invalid"] += 1
        return
    stats["echo_json_valid"] += 1
    stats["echo_keys_equal_current_v3_header"] += int(
        set(metadata) == {"capture_status", "captured_utc", "event_id", "role", "source_time"})
    stats["echo_role_" + str(metadata.get("role"))] += 1
    event_id = str(metadata.get("event_id", ""))
    parsed, last = jc.EVENT_ID.match(event_id), jc.EVENT_ID.match(recent_ids[-1]) if recent_ids else None
    if event_id in recent_ids:
        stats["echo_event_id_copies_a_delivered_recent_id"] += 1
    elif parsed and last and parsed["q"] == last["q"] and parsed["s"] == last["s"] and \
            int(parsed["m"]) == int(last["m"]) + 1:
        stats["echo_event_id_is_next_after_last_recent"] += 1
    else:
        stats["echo_event_id_other"] += 1
    try:
        jc.dataset_message(dataset, event_id)
        stats["echo_event_id_exists_in_history"] += 1
    except jc.CalibrationError:
        stats["echo_event_id_absent_from_history"] += 1
    if recent_ids:
        last_message = jc.dataset_message(dataset, recent_ids[-1])
        stats["echo_last_recent_role_" + last_message["role"]] += 1
        source_time = metadata.get("source_time") if isinstance(metadata.get("source_time"), dict) else {}
        stats["echo_source_date_equals_last_recent_date"] += int(source_time.get("original_value") == last_message["date"])
    rest = candidate["answer_text"][match.end():]
    question = _normalized(candidate["question"] or "").rstrip("?").strip()
    stats["echo_followed_by_question_verbatim"] += int(bool(question) and question in _normalized(rest))


def measure(roots, dataset, calibration_set=None, item_ids=()):
    candidates = [c for c in jc.collect_candidates(roots, dataset) if c["answer_text"] is not None]
    recent = recent_sources(roots)
    groups = defaultdict(new_group)
    families = defaultdict(new_group)
    cross = defaultdict(Counter)
    provenance = Counter()
    echo_questions, framed_questions = set(), set()
    per_key = {}
    for candidate in candidates:
        counts = pattern_counts(candidate["answer_text"], candidate["question"])
        per_key[candidate["key"]] = counts
        family = candidate["answerer_family"]
        add(groups[(candidate["run"], candidate["arm"], family)], counts)
        add(families[(candidate["run_family"], family)], counts)
        echoed = counts["envelope_recent_heading"] > 0 or counts["envelope_original_text_label"] > 0
        if candidate["key"] in recent:
            ids = recent[candidate["key"]]
            assistants = sum(jc.dataset_message(dataset, event_id)["role"] == "assistant" for event_id in ids)
            bucket = "recent_assistant_messages_" + ("0" if assistants == 0 else "1_plus")
            cross[bucket]["answers"] += 1
            cross[bucket]["envelope_echo"] += int(echoed)
            arm = "framed_recent_" + candidate["arm"]
            cross[arm]["answers"] += 1
            cross[arm]["envelope_echo"] += int(echoed)
            framed_questions.add(candidate["question_id"])
            if echoed:
                echo_questions.add(candidate["question_id"])
            echo_provenance(candidate, ids, dataset, provenance)
        flags = context_flags(candidate["evidence"])
        bucket = f"{family}/context_inline_math_{str(flags['context_inline_math']).lower()}"
        cross[bucket]["answers"] += 1
        cross[bucket]["answer_inline_math"] += int(counts["math_inline_dollar_pair"] > 0)
    result = {
        "tool_version": TOOL_VERSION,
        "answers_measured": len(candidates),
        "patterns": {name: {"category": category, "description": description}
                     for name, (category, description) in PATTERNS.items()},
        "by_run_arm_family": [{"run": run, "arm": arm, "answerer_family": family, **finish(group)}
                              for (run, arm, family), group in sorted(groups.items())],
        "by_run_family": [{"run_family": run_family, "answerer_family": family, **finish(group)}
                          for (run_family, family), group in sorted(families.items())],
        "cross_tabs": {key: dict(value) for key, value in sorted(cross.items())},
        "envelope_echo_provenance": {**dict(sorted(provenance.items())),
                                     "distinct_questions_with_echo": len(echo_questions),
                                     "distinct_questions_with_framed_recent": len(framed_questions)},
    }
    if calibration_set is not None:
        key_items = {entry["item_id"]: entry for entry in jc.load_json(calibration_set / "key.json")["items"]}
        items = {}
        selected = new_group()
        for item_id in item_ids:
            entry = key_items.get(item_id)
            jc.require(entry is not None, "calibration_item_missing")
            counts = per_key.get(entry["key"])
            jc.require(counts is not None, "calibration_answer_missing")
            items[item_id] = {"run": entry["run"], "arm": entry["arm"], "answerer_family": entry["answerer_family"],
                              "counts": {name: value for name, value in counts.items() if value}}
            add(selected, counts)
        result["calibration_items"] = items
        result["calibration_items_total"] = finish(selected)
    return result


# --------------------------------------------------------------------------- current envelope


def framing_literals(framing_path: Path = FRAMING_SOURCE, assembler_path: Path = ASSEMBLER_SOURCE) -> dict:
    """Read the envelope literals from Swift source so the rendering tracks the checkout."""
    framing = framing_path.read_text()
    assembler = assembler_path.read_text()

    def literal(name):
        match = re.search(r'static let ' + name + r' = "((?:[^"\\]|\\.)*)"', framing)
        jc.require(match is not None, "framing_literal_missing")
        return match.group(1).encode().decode("unicode_escape")

    original = re.search(r'recentMetadataHeading \+ metadata \+ "((?:[^"\\]|\\.)*)"', framing)
    headers = re.findall(r'return """\n(.*?)\n\s*""" \+ "\\n"', framing, re.S)
    history = re.search(r'private static let historyFraming = """\n(.*?)\n\s*"""', assembler, re.S)
    quoted_history = re.search(r'private static let quotedHistoryFraming = """\n(.*?)\n\s*"""', assembler, re.S)
    quoted_fields = re.search(r'quotedRecentNote \+ (.*?)\n\s*\}', framing, re.S)
    jc.require(original is not None and len(headers) == 2 and history is not None and quoted_history is not None
               and quoted_fields is not None, "framing_literal_missing")
    # The V4 block (labelled, no event_id line) precedes the V1 to V3 block in the source.
    quoted_header, header = ([line.strip() for line in block.splitlines()] for block in headers)
    jc.require(header[1].startswith("event_id:") and quoted_header[0].startswith("BEGIN HISTORICAL SOURCE [")
               and not any(line.startswith("event_id:") for line in quoted_header), "framing_literal_missing")
    field_names = re.findall(r'"(?:\\n)?([a-z_]+): "', quoted_fields.group(1))
    return {"recent_heading": literal("recentMetadataHeading"),
            "original_label": original.group(1).encode().decode("unicode_escape"),
            "evidence_prefix": literal("evidencePrefix"), "evidence_separator": literal("evidenceSeparator"),
            "evidence_footer": literal("evidenceFooter"), "evidence_header_lines": header,
            "history_framing": history.group(1).strip(),
            "quoted_recent_heading": literal("quotedRecentHeading"), "quoted_recent_note": literal("quotedRecentNote"),
            "quoted_recent_fields": field_names, "quoted_evidence_header_lines": quoted_header,
            "quoted_history_framing": quoted_history.group(1).strip()}


def _metadata_json(fields: dict) -> str:
    return json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def render_envelope(literals: dict, system: str = "Be helpful, concise, and accurate.", version: str = "v3") -> list:
    """Synthetic messages in the order ContextAssembler produces for a hybrid turn (v3 or v4 selection)."""
    if version == "v4":
        return render_quoted_envelope(literals, system)
    source_time = {"locator": "/synthetic/0", "original_value": "2023/01/01 (Sun) 10:00", "precision": "minute",
                   "source_sha256": "0" * 64, "timezone": "unspecified", "value": "2023-01-01T10:00"}

    def recent(event_id, role, text):
        metadata = _metadata_json({"capture_status": "complete", "captured_utc": "2026-10-06T00:00:00Z",
                                   "event_id": event_id, "role": role, "source_time": source_time})
        return {"role": "user" if role == "human" else "assistant",
                "content": literals["recent_heading"] + metadata + literals["original_label"] + text}

    header = "\n".join(literals["evidence_header_lines"])
    substitutions = {r"\(eventID)": "synthetic-s0000-m0001", r"\(conversationID)": "synthetic-conversation",
                     r"\(role)": "assistant", r"\(status)": "complete",
                     r"\(chronology)": "captured_utc: 2026-10-06T00:00:00Z\nsource_time: " + _metadata_json(source_time),
                     r"\(digest)": "0" * 64, r"\(offset)": "0", r"\(totalBytes)": "26"}
    for placeholder, value in substitutions.items():
        header = header.replace(placeholder, value)
    evidence = (literals["evidence_prefix"] + header + "\n" + "Synthetic historical reply." + literals["evidence_footer"])
    return [{"role": "system", "content": system + "\n\n" + literals["history_framing"]},
            recent("synthetic-s0001-m0000", "human", "Synthetic earlier question."),
            recent("synthetic-s0001-m0001", "assistant", "Synthetic earlier answer."),
            {"role": "user", "content": evidence},
            {"role": "user", "content": "Question Date: 2023/01/02 (Mon) 09:00\nQuestion: Synthetic question?"}]


def render_quoted_envelope(literals: dict, system: str) -> list:
    """V4: prior turns are host-quoted user messages with labels; the excerpt continues the labels."""
    source_time = {"locator": "/synthetic/0", "original_value": "2023/01/01 (Sun) 10:00", "precision": "minute",
                   "source_sha256": "0" * 64, "timezone": "unspecified", "value": "2023-01-01T10:00"}
    values = {"capture_status": "complete", "captured_utc": "2026-10-06T00:00:00Z", "source_time": _metadata_json(source_time)}

    def recent(position, role, text):
        fields = "".join(name + ": " + (role if name == "role" else values[name]) + "\n"
                         for name in literals["quoted_recent_fields"] if name != "quoted_text")
        return {"role": "user", "content": literals["quoted_recent_heading"] + "[E" + str(position) + "]"
                + literals["quoted_recent_note"] + fields + "quoted_text:\n" + text}

    header = "\n".join(literals["quoted_evidence_header_lines"])
    substitutions = {r"\(label)": "E3", r"\(conversationID)": "synthetic-conversation", r"\(role)": "assistant",
                     r"\(status)": "complete",
                     r"\(chronology)": "captured_utc: 2026-10-06T00:00:00Z\nsource_time: " + _metadata_json(source_time),
                     r"\(digest)": "0" * 64, r"\(offset)": "0", r"\(totalBytes)": "26"}
    for placeholder, value in substitutions.items():
        header = header.replace(placeholder, value)
    evidence = (literals["evidence_prefix"] + header + "\n" + "Synthetic historical reply."
                + literals["evidence_footer"] + " [E3]")
    return [{"role": "system", "content": system + "\n\n" + literals["quoted_history_framing"]},
            recent(1, "human", "Synthetic earlier question."),
            recent(2, "assistant", "Synthetic earlier answer."),
            {"role": "user", "content": evidence},
            {"role": "user", "content": "Question Date: 2023/01/02 (Mon) 09:00\nQuestion: Synthetic question?"}]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    measuring = commands.add_parser("measure")
    measuring.add_argument("--evaluation-root", action="append", required=True)
    measuring.add_argument("--dataset", type=Path, required=True)
    measuring.add_argument("--calibration-set", type=Path)
    measuring.add_argument("--item", action="append", default=[])
    commands.add_parser("envelope")
    args = parser.parse_args(argv)
    try:
        if args.command == "measure":
            roots = jc.parse_roots(args.evaluation_root)
            dataset = jc.load_dataset(args.dataset)
            result = measure(roots, dataset, args.calibration_set, args.item)
        else:
            literals = framing_literals()
            result = {"tool_version": TOOL_VERSION, "literals": literals,
                      "messages_v3": render_envelope(literals, version="v3"),
                      "messages_v4": render_envelope(literals, version="v4"),
                      "assistant_turns_starting_with_host_text": {
                          version: sum(message["role"] == "assistant" and message["content"].startswith(
                              (RECENT_HEADING, QUOTED_HEADING, INCOMPLETE_NOTICE))
                              for message in render_envelope(literals, version=version))
                          for version in ("v3", "v4")}}
        print(json.dumps(result, indent=1, ensure_ascii=False))
    except jc.CalibrationError as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
