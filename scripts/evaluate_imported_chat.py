#!/usr/bin/env python3
"""Offline, content-free retrieval diagnostics for a verified Boros chat import."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CORE = tuple("Sources/Boros/" + name + ".swift" for name in (
    "MemoryStore", "AuthorityState", "AuthorityStateJournal", "AuthorityBindings", "AuthorityBindingJournal", "AuthorityValidation", "BackgroundIndexBudget", "BackgroundIndexJournal", "ContextComponentJournal",
    "QwenTextRendering", "ContextSourceFraming", "ContextAssembler", "ChatContextPreparation",
    "SemanticIndex", "BackgroundIndexWorker", "EpisodeBudget", "EpisodeLease", "EpisodeSQLFence", "MeteredRetrieval"))
SUPPORT = ("Tests/Evaluation/ImportedChatHarness.swift", "Sources/CSQLite/module.modulemap", "Sources/CSQLite/shim.h")
PROTOCOLS = ("recent_only", "lexical_context", "hybrid_context", "raw_pages")
MAX_BYTES = 128 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
WORDS = re.compile(r"[A-Za-z][A-Za-z0-9]{3,63}")


class EvaluationError(Exception):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def strict_json(data: bytes):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise EvaluationError("duplicate JSON fields")
            value[key] = item
        return value
    def invalid(_):
        raise EvaluationError("nonfinite JSON value")
    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=invalid)


def read_file(path: Path, limit=MAX_BYTES) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= limit:
            raise EvaluationError("invalid input file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise EvaluationError("input too large")
    return data


def private_write(path: Path, data: bytes):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def load_import(directory: Path, scratch: Path) -> tuple[list[dict], dict]:
    """Read-only SQLite backup, then verify only manifest-bound imported events.

    Existing GUI ownership is harmless: no MemoryStore owner opens the original.
    Later user turns are excluded. Runtime ledgers/settings/vectors are not copied
    into the diagnostic store; only the verified imported source messages are.
    """
    if directory.is_symlink() or not directory.is_dir():
        raise EvaluationError("invalid imported store")
    manifest_bytes = read_file(directory / "import-manifest.json")
    manifest = strict_json(manifest_bytes)
    if not isinstance(manifest, dict) or type(manifest.get("version")) is not int or manifest.get("version") != 1:
        raise EvaluationError("invalid import manifest")
    records = manifest.get("imported_messages")
    import_hash = manifest.get("import_sha256")
    if not isinstance(import_hash, str) or not SHA.fullmatch(import_hash):
        raise EvaluationError("invalid import digest")
    canonical_bytes = read_file(directory / "chat-import.json")
    if digest(canonical_bytes) != import_hash:
        raise EvaluationError("canonical import digest mismatch")
    document = strict_json(canonical_bytes)
    if not isinstance(records, list) or not 1 <= len(records) <= 100_000:
        raise EvaluationError("invalid imported messages")
    if (not isinstance(document, dict) or type(document.get("schema_version")) is not int
            or document.get("schema_version") != 1 or not isinstance(document.get("messages"), list)
            or not integer(manifest.get("input_messages"), len(records), 100_000)
            or len(document["messages"]) != manifest["input_messages"]
            or document.get("source") != manifest.get("source")):
        raise EvaluationError("invalid canonical import")
    origin_verified = manifest.get("original_source_verified") is True
    if origin_verified:
        original = document.get("original_json")
        declared = document.get("source", {}).get("sha256")
        if (not isinstance(original, str) or not isinstance(declared, str) or not SHA.fullmatch(declared)
                or digest(original.encode()) != declared or digest(read_file(directory / "chat-source.json")) != declared):
            raise EvaluationError("original source mismatch")
    if manifest.get("project_id") != "default" or not isinstance(manifest.get("conversation_id"), str):
        raise EvaluationError("invalid import scope")
    database_path = directory / "memory.sqlite3"
    if database_path.is_symlink() or not database_path.is_file():
        raise EvaluationError("invalid database")
    snapshot = scratch / "source-snapshot.sqlite3"
    # The snapshot includes committed WAL contents. Never copy a live main file
    # with shutil and assume it includes accepted events.
    backup_deadline = time.monotonic() + 30
    def backup_progress(_status, _remaining, _total):
        if time.monotonic() > backup_deadline:
            raise EvaluationError("source snapshot deadline exceeded")
    with sqlite3.connect(database_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=5) as source:
        source.execute("PRAGMA query_only=ON")
        with sqlite3.connect(snapshot) as destination:
            source.backup(destination, pages=256, sleep=0.05, progress=backup_progress)
    os.chmod(snapshot, 0o600)
    messages = []
    total = 0
    with sqlite3.connect(snapshot.as_uri() + "?mode=ro", uri=True) as database:
        ordered = database.execute(
            "SELECT id, sequence "
            "FROM events WHERE conversation_id=? ORDER BY sequence", (manifest["conversation_id"],)).fetchall()
        # Verify their relative order, while allowing unrelated later GUI turns.
        imported_ids = {record.get("event_id") for record in records if isinstance(record, dict)}
        imported_order = [row[0] for row in ordered if row[0] in imported_ids]
        if len(imported_order) != len(records):
            raise EvaluationError("imported source missing")
        for ordinal, (record, event_id) in enumerate(zip(records, imported_order)):
            if (not isinstance(record, dict) or type(record.get("ordinal")) is not int
                    or record.get("ordinal") != ordinal or record.get("event_id") != event_id
                    or not integer(record.get("source_bytes"), 0, 4 * 1024 * 1024)):
                raise EvaluationError("invalid import order")
            row = database.execute("SELECT id, project_id, role, status, turn_id, payload, digest, sequence "
                                   "FROM events WHERE id=? AND conversation_id=? AND length(payload)<=?",
                                   (event_id, manifest["conversation_id"], 4 * 1024 * 1024)).fetchone()
            if row is None:
                raise EvaluationError("invalid imported source")
            text_bytes = bytes(row[5])
            role = {"human": "user", "assistant": "assistant"}.get(row[2])
            canonical_message = document["messages"][ordinal]
            if (not isinstance(canonical_message, dict) or canonical_message.get("role") != role
                    or canonical_message.get("status") != row[3] or not isinstance(canonical_message.get("content"), str)
                    or canonical_message["content"].encode() != text_bytes):
                raise EvaluationError("canonical source mismatch")
            if (row[0] != record.get("event_id") or row[0] != f"import-{import_hash}-{ordinal}"
                    or row[1] != "default" or role != record.get("role") or row[3] != record.get("status")
                    or row[4] != record.get("turn_id") or len(text_bytes) != record.get("source_bytes")
                    or digest(text_bytes) != record.get("sha256") or row[6] != record.get("sha256")
                    or len(text_bytes) > 4 * 1024 * 1024):
                raise EvaluationError("imported source mismatch")
            total += len(text_bytes)
            if total > MAX_BYTES:
                raise EvaluationError("imported source too large")
            messages.append({"id": row[0], "role": row[2], "status": row[3], "turnID": row[4], "text": text_bytes.decode("utf-8"),
                             "sha256": row[6]})
    return messages, {"importSHA256": import_hash, "manifestSHA256": digest(manifest_bytes),
                      "orderedMessagesSHA256": digest(canonical([
                          {key: message[key] for key in ("id", "role", "status", "turnID", "sha256")} for message in messages])),
                      "messageCount": len(messages), "sourceBytes": total,
                      "sourceVerifiedAgainstImportManifest": True,
                      "originalSourceBytesVerified": origin_verified,
                      "laterApplicationTurnsIncluded": False}


def position(ordinal, count):
    if ordinal == count - 1:
        return "recent"
    fraction = ordinal / max(1, count - 1)
    return "early" if fraction < 1 / 3 else "middle" if fraction < 2 / 3 else "late"


def automatic_probes(messages: list[dict], count: int) -> list[dict]:
    """Deterministic source-derived phrase probes, explicitly not natural gold.

    Rank words by source frequency; ask using up to three terms. Gold is a
    longer original range around a term. The scorer never treats prompt echoes
    or occurrences in a different source as delivered evidence.
    """
    frequencies = Counter()
    matches = []
    for message in messages:
        found = list(WORDS.finditer(message["text"]))
        matches.append(found)
        frequencies.update({match.group().lower() for match in found})
    eligible = [i for i, found in enumerate(matches) if found]
    if not eligible:
        raise EvaluationError("no automatic phrase probes; supply a probe file")
    count = min(count, len(eligible))
    selected = sorted({eligible[round(i * (len(eligible) - 1) / max(1, count - 1))] for i in range(count)})
    probes = []
    for ordinal in selected:
        message = messages[ordinal]
        found = matches[ordinal]
        best = min(found, key=lambda match: (frequencies[match.group().lower()], -len(match.group()), match.start()))
        # Character slicing first guarantees complete UTF-8 boundaries.
        start = best.start()
        end = min(len(message["text"]), best.end() + 90)
        while len(message["text"][start:end].encode()) > 256:
            end -= 1
        text = message["text"][start:end]
        terms = sorted({match.group().lower() for match in WORDS.finditer(text)},
                       key=lambda word: (frequencies[word], -len(word), word))[:3]
        query = " ".join(terms)
        offset = len(message["text"][:start].encode())
        data = text.encode()
        probes.append({"prompt": "Find the earlier discussion containing these terms: " + query,
                       "query": query, "literal": best.group(), "region": position(ordinal, len(messages)),
                       "kind": "answerable", "gold": [{"message": ordinal, "offset": offset,
                                                         "bytes": len(data), "sha256": digest(data)}]})
    absent = "borosabsent" + digest(canonical([m["sha256"] for m in messages]))[:32]
    if any(absent.lower() in message["text"].lower() for message in messages):
        raise EvaluationError("absence sentinel collision")
    probes.append({"prompt": "Find the earlier discussion containing " + absent, "query": absent,
                   "literal": absent, "region": "absent", "kind": "absent", "gold": []})
    return probes


def validate_probes(document, messages, import_hash):
    if (not isinstance(document, dict) or set(document) != {"schema_version", "import_sha256", "probes"}
            or type(document["schema_version"]) is not int or document["schema_version"] != 1
            or document["import_sha256"] != import_hash or not isinstance(document["probes"], list)
            or not 1 <= len(document["probes"]) <= 200):
        raise EvaluationError("invalid probe document")
    result = []
    for probe in document["probes"]:
        if not isinstance(probe, dict) or not {"prompt", "gold"} <= set(probe) <= {"prompt", "gold", "query", "literal"}:
            raise EvaluationError("invalid probe fields")
        prompt = probe["prompt"]
        query = probe.get("query", prompt)
        literal = probe.get("literal")
        if (not isinstance(prompt, str) or not 1 <= len(prompt.encode()) <= 16_384
                or not isinstance(query, str) or not 1 <= len(query.encode()) <= 1024
                or "\x00" in query or (literal is not None and
                    (not isinstance(literal, str) or not 1 <= len(literal.encode()) <= 1024 or "\x00" in literal))
                or not isinstance(probe["gold"], list) or len(probe["gold"]) > 16):
            raise EvaluationError("invalid probe values")
        golds = []
        for gold in probe["gold"]:
            if (not isinstance(gold, dict) or set(gold) != {"message", "offset", "bytes", "sha256"}
                    or not integer(gold["message"], 0, len(messages) - 1)
                    or not integer(gold["offset"], 0, 4 * 1024 * 1024)
                    or not integer(gold["bytes"], 1, 4 * 1024 * 1024)
                    or not isinstance(gold["sha256"], str) or not SHA.fullmatch(gold["sha256"])):
                raise EvaluationError("invalid gold span")
            data = messages[gold["message"]]["text"].encode()
            end = gold["offset"] + gold["bytes"]
            if end > len(data) or digest(data[gold["offset"]:end]) != gold["sha256"]:
                raise EvaluationError("gold span mismatch")
            data[:gold["offset"]].decode("utf-8")
            data[gold["offset"]:end].decode("utf-8")
            golds.append(gold)
        region = position(golds[0]["message"], len(messages)) if golds else "absent"
        result.append({"prompt": prompt, "query": query, "literal": literal, "gold": golds,
                       "region": region, "kind": "answerable" if golds else "absent"})
    return result


def compile_harness(scratch: Path):
    relatives = list(CORE + SUPPORT + ("scripts/evaluate_imported_chat.py",))
    # Current development source can depend on this in-progress strategy enum.
    # Hash and copy it when present; no edits to that independently owned file.
    strategy = "Sources/Boros/ContextRetrievalStrategy.swift"
    if (ROOT / strategy).exists():
        relatives.append(strategy)
    hashes = {}
    captured = scratch / "source"
    for relative in relatives:
        destination = captured / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        data = (ROOT / relative).read_bytes()
        destination.write_bytes(data)
        hashes[relative] = digest(data)
    binary = scratch / "imported-chat-evaluation"
    command = ["/usr/bin/swiftc", "-O", "-swift-version", "5", "-parse-as-library",
               "-I", str(captured / "Sources/CSQLite"), "-framework", "NaturalLanguage",
               "-o", str(binary), *(str(captured / name) for name in relatives if name.endswith(".swift"))]
    process = subprocess.run(command, capture_output=True, timeout=180)
    if process.returncode:
        raise EvaluationError("offline harness compilation failed")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    return binary, {"gitRevision": revision, "sourceSHA256": hashes,
                    "compilerFlags": ["-O", "-swift-version", "5", "-parse-as-library", "-framework", "NaturalLanguage"],
                    "sourceSnapshot": "copied before compilation; includes current uncommitted source"}


def execute(binary, mode, input_path, runtime, output):
    process = subprocess.run([str(binary), mode, str(input_path), str(runtime), str(output)],
                             capture_output=True, timeout=900, env={**os.environ, "BOROS_DATA_DIR": str(runtime)})
    if process.returncode:
        raise EvaluationError("offline harness failed; no content diagnostics emitted")
    return strict_json(read_file(output))


def summarize(report):
    summary = {}
    for protocol in PROTOCOLS:
        results = [(probe, probe["protocols"][protocol]) for probe in report["probes"]]
        durations = sorted(row["fullEpisodeMilliseconds"] for _, row in results if row["status"] != "skipped")
        eligible = [(probe, row) for probe, row in results if probe["kind"] == "answerable"]
        regions = {}
        for region in ("early", "middle", "late", "recent"):
            selected = [row for probe, row in eligible if probe["region"] == region]
            regions[region] = {"probes": len(selected), "covered": sum(row["allRequiredSpansPresent"] for row in selected)}
        summary[protocol] = {"answerableProbes": len(eligible),
                             "coveredProbes": sum(row["allRequiredSpansPresent"] for _, row in eligible),
                             "failures": sum(row["status"] == "error" for _, row in results),
                             "skipped": sum(row["status"] == "skipped" for _, row in results),
                             "coverageLimited": sum(bool(row["coverageLimits"]) for _, row in results),
                             "absenceProbesWithHits": sum(row["sourceCount"] > 0 for probe, row in results if probe["kind"] == "absent") if protocol == "raw_pages" else None,
                             "fullEpisodeMillisecondsP95": durations[math.ceil(0.95 * len(durations)) - 1] if durations else None,
                             "regions": regions}
    return summary


def run(args):
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise EvaluationError("report already exists; choose a new output path")
    with tempfile.TemporaryDirectory(prefix="boros-imported-evaluation-") as temporary:
        scratch = Path(temporary)
        os.chmod(scratch, 0o700)
        print("Verifying imported sources; original store opened read-only.", flush=True)
        messages, provenance = load_import(args.store.absolute(), scratch)
        if args.probe_file:
            data = read_file(args.probe_file, 8 * 1024 * 1024)
            probes = validate_probes(strict_json(data), messages, provenance["importSHA256"])
            probe_mode = "user-supplied-known-spans"
        else:
            probes = automatic_probes(messages, args.probes)
            data = canonical(probes)
            probe_mode = "corpus-derived-phrase-diagnostic"
        fixture = {"version": 1, "messages": messages, "probes": probes,
                   "semanticChunks": args.semantic_chunks, "indexSeconds": args.index_seconds,
                   "memoryOperationCap": args.memory_operations}
        input_path = scratch / "input.json"
        fixture_bytes = canonical(fixture)
        if len(fixture_bytes) > MAX_BYTES:
            raise EvaluationError("diagnostic input too large")
        private_write(input_path, fixture_bytes)
        print("Compiling captured Boros retrieval sources.", flush=True)
        binary, implementation = compile_harness(scratch)
        runtime = scratch / "runtime"
        profiles = {}
        print("Running offline retrieval diagnostics; no answering model requests.", flush=True)
        warm = execute(binary, "warm", input_path, runtime, scratch / "warm.json")
        profiles["warm"] = {"report": warm, "summary": summarize(warm)}
        if args.profile == "both":
            print("Repeating in a fresh process with the retained diagnostic index.", flush=True)
            restart = execute(binary, "restart", input_path, runtime, scratch / "restart.json")
            profiles["process_restart"] = {"report": restart, "summary": summarize(restart)}
        report = {"importedChatEvaluationSchemaVersion": 1, "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
                  "purpose": "unregistered offline imported-chat source selection diagnostic",
                  "registrationStatus": "unregistered", "officialBenchmarkScore": False,
                  "probeMode": probe_mode, "probeSHA256": digest(data), "probeCount": len(probes),
                  "source": provenance, "implementation": implementation, "profiles": profiles,
                  "providerRequests": 0, "providerTokenFeasibility": None, "answerQuality": None,
                  "limitations": ["one selected imported conversation; no population-level recall claim",
                                  "source-derived phrase probes are targeted diagnostics, not independent natural questions",
                                  "65,536 serialized context bytes, 24,000 recent bytes, 12,000 evidence bytes; no provider-token admission",
                                  "legacy byte-bounded ChatContextPreparation selector; selected-Qwen staged token reduction is not run",
                                  "partial/unsupported semantic coverage and failures remain in denominators; skipped hybrid is unavailable",
                                  "protocol order fixed; warm caches and OS cache uncontrolled after process restart",
                                  "only verified imported messages reingested; runtime ledgers, later turns and existing vectors excluded",
                                  "no original timestamp/temporal benchmark adaptation or model answer scoring"]}
        output.parent.mkdir(parents=True, exist_ok=True)
        private_write(output, canonical(report) + b"\n")
        for profile, value in profiles.items():
            print(json.dumps({"profile": profile, "summary": value["summary"]}, sort_keys=True, allow_nan=False))
        print("Metadata-only report: " + str(output))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True, help="Existing imported-chat store (read-only)")
    parser.add_argument("--output", type=Path, required=True, help="New metadata-only JSON report; never overwritten")
    parser.add_argument("--profile", choices=("warm", "both"), default="both")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--probes", type=int, default=12, help="1–100 automatic answerable phrase probes, plus one absence probe")
    selection.add_argument("--probe-file", type=Path, help="Private JSON questions with verified source byte spans")
    parser.add_argument("--semantic-chunks", type=int, default=4096, help="0 disables hybrid; otherwise 1–4096 indexing attempts")
    parser.add_argument("--index-seconds", type=int, default=60, help="1–300 second indexing scheduling bound; each chunk batch can finish afterward")
    parser.add_argument("--memory-operations", type=int, default=24, help="0–24 memory operations per retrieval attempt")
    args = parser.parse_args()
    if not (1 <= args.probes <= 100 and 0 <= args.semantic_chunks <= 4096
            and 1 <= args.index_seconds <= 300 and 0 <= args.memory_operations <= 24):
        parser.error("diagnostic limits outside supported ranges")
    try:
        run(args)
    except EvaluationError as error:
        # This class contains only fixed host-authored reason strings.
        print("Imported-chat evaluation failed: " + str(error) + ".", file=sys.stderr)
        return 1
    except Exception:
        # SQLite, JSON and compiler diagnostics can include input material.
        print("Imported-chat evaluation failed. Check inputs, source integrity, compiler availability and a new output path.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
