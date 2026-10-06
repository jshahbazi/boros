#!/usr/bin/env python3
"""Convert public text chats and publish a fresh private Boros test store.

No prompt, response, title, source ID, or URL is printed. Network access only
downloads an explicitly supplied HTTPS source; ingestion invokes local Boros.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MAX_INPUT_BYTES = 128 * 1024 * 1024
MAX_MESSAGE_BYTES = 4 * 1024 * 1024
MAX_MESSAGES = 100_000
FORMATS = ("auto", "openai", "sharegpt", "beam", "devgpt")


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _parse(raw):
    text = raw.decode("utf-8", errors="strict")
    def decode(value):
        return json.loads(value, object_pairs_hook=_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite JSON number")))
    try:
        return decode(text)
    except json.JSONDecodeError:
        # JSONL is a sequence of whole JSON documents, never a repair of
        # malformed multiline JSON. Duplicate-key errors do not reach here.
        lines = [line for line in text.splitlines() if line.strip()]
        if len(lines) < 2:
            raise
        return [decode(line) for line in lines]


def _read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_INPUT_BYTES:
            raise ValueError("source must be a bounded regular file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            raise ValueError("source exceeds document limit")
        return raw
    finally:
        os.close(fd)


def load_input(path):
    return _parse(_read(path))


def normalize_time(literal):
    """Preserve explicit calendar precision and zone; never infer an instant."""
    if not isinstance(literal, str) or len(literal.encode("utf-8")) > 128:
        raise ValueError("unsupported source time")
    iso = re.fullmatch(r"([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(\.[0-9]{1,9})?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?", literal)
    local = re.fullmatch(r"([0-9]{4})/([0-9]{2})/([0-9]{2}) \((Sun|Mon|Tue|Wed|Thu|Fri|Sat)\)(?: ([0-9]{2}):([0-9]{2}))?", literal)
    match = iso or local
    if match is None:
        raise ValueError("unsupported source time")
    parts = match.groups()
    date = datetime.date(*(int(p) for p in parts[:3]))
    if local and ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")[date.weekday()] != parts[3]:
        raise ValueError("source weekday mismatch")
    value, precision, zone = date.isoformat(), "day", "unspecified"
    hour, minute = parts[4:6] if local else parts[3:5]
    if hour is not None:
        if not 0 <= int(hour) <= 23 or not 0 <= int(minute) <= 59:
            raise ValueError("invalid source time")
        value += "T" + hour + ":" + minute
        precision = "minute"
        if iso:
            second, fraction, zone = parts[5:8]
            zone = zone or "unspecified"
            if second is not None:
                if not 0 <= int(second) <= 59:
                    raise ValueError("invalid source time")
                value += ":" + second + (fraction or "")
                precision = "fractional_second" if fraction else "second"
            if zone not in ("Z", "unspecified"):
                zh, zm = int(zone[1:3]), int(zone[4:6])
                if zh > 14 or zm > 59 or zh == 14 and zm != 0 or zone == "-00:00":
                    raise ValueError("unsupported source zone")
    return {"value": value, "precision": precision, "timezone": zone}


def normalize(messages):
    if not isinstance(messages, list) or not 0 < len(messages) <= MAX_MESSAGES:
        raise ValueError("invalid message count")
    result = []
    aliases = {"user": "user", "human": "user", "assistant": "assistant", "gpt": "assistant"}
    for message in messages:
        if not isinstance(message, dict) or not {"role", "content"} <= message.keys() <= {"role", "content", "status", "timestamp"}:
            raise ValueError("unsupported message fields")
        role, text, status = message["role"], message["content"], message.get("status", "complete")
        if not isinstance(role, str) or role not in aliases or not isinstance(text, str):
            raise ValueError("only text user and assistant messages are supported")
        if status not in ("complete", "partial", "failed", "cancelled"):
            raise ValueError("unsupported capture status")
        if len(text.encode("utf-8", errors="strict")) > MAX_MESSAGE_BYTES:
            raise ValueError("message exceeds capture limit")
        normalized = {"role": aliases[role], "content": text, "status": status}
        if "timestamp" in message:
            normalize_time(message["timestamp"])
            normalized["timestamp"] = message["timestamp"]
        result.append(normalized)
    return result


def dated_messages(root, chat, raw):
    """Bind explicit message timestamps to exact original document locations."""
    messages = normalize(chat)
    if not any("timestamp" in message for message in messages):
        return messages
    # OpenAI adapters retain the actual source list. Converted BEAM, DevGPT,
    # and ShareGPT lists contain no accepted timestamp field.
    if chat is root:
        prefix = ""
    elif isinstance(root, dict):
        keys = [key for key in ("messages", "conversation") if root.get(key) is chat]
        if len(keys) != 1:
            raise ValueError("source date location unavailable")
        prefix = "/" + keys[0]
    elif isinstance(root, list):
        found = [(index, key) for index, record in enumerate(root) if isinstance(record, dict)
                 for key in ("messages", "conversation") if record.get(key) is chat]
        if len(found) != 1:
            raise ValueError("source date location unavailable")
        index, key = found[0]
        prefix = f"/{index}/{key}"
    else:
        raise ValueError("source date location unavailable")
    digest = hashlib.sha256(raw).hexdigest()
    for index, message in enumerate(messages):
        if "timestamp" in message:
            literal = message.pop("timestamp")
            message["source_time"] = {**normalize_time(literal), "original_value": literal,
                                      "source_sha256": digest, "locator": f"{prefix}/{index}/timestamp"}
    return messages


def _message_array(value):
    return isinstance(value, list) and bool(value) and all(isinstance(m, dict) and "role" in m and "content" in m for m in value)


def conversations(root, format="auto"):
    """Return source chats in file order. Adapters never infer roles from prose."""
    if format not in FORMATS:
        raise ValueError("unsupported format")
    if format == "auto":
        if isinstance(root, dict) and "Sources" in root:
            format = "devgpt"
        elif isinstance(root, dict) and "ChatgptSharing" in root:
            format = "devgpt"
        elif isinstance(root, list) and root and isinstance(root[0], dict) and "ChatgptSharing" in root[0]:
            format = "devgpt"
        elif isinstance(root, list) and root and isinstance(root[0], dict) and "turns" in root[0]:
            format = "beam"
        elif isinstance(root, dict) and "conversations" in root:
            format = "sharegpt"
        elif isinstance(root, list) and root and isinstance(root[0], dict) and "conversations" in root[0]:
            format = "sharegpt"
        else:
            format = "openai"
    if format == "beam":
        if not isinstance(root, list) or not root:
            raise ValueError("BEAM requires a nonempty batch list")
        messages = []
        for batch in root:
            if not isinstance(batch, dict) or not isinstance(batch.get("turns"), list):
                raise ValueError("malformed BEAM batch")
            for turn in batch["turns"]:
                if not isinstance(turn, list) or not turn:
                    raise ValueError("malformed BEAM turn")
                for message in turn:
                    if not isinstance(message, dict) or not {"role", "content"} <= message.keys() <= {
                        "role", "content", "id", "time_anchor", "index", "question_type", "status"
                    }:
                        raise ValueError("unsupported BEAM message")
                    messages.append({key: message[key] for key in ("role", "content", "status") if key in message})
        return [messages]
    if format == "devgpt":
        records = root.get("Sources") if isinstance(root, dict) and "Sources" in root else root
        if isinstance(records, dict):
            records = [records]
        if not isinstance(records, list) or not records:
            raise ValueError("DevGPT requires source records")
        result = []
        for record in records:
            if not isinstance(record, dict) or not isinstance(record.get("ChatgptSharing"), list):
                raise ValueError("malformed DevGPT source")
            for sharing in record["ChatgptSharing"]:
                if not isinstance(sharing, dict):
                    raise ValueError("malformed DevGPT sharing")
                pairs = sharing.get("Conversations")
                # Failed/deleted shares are source metadata, not conversations.
                if pairs is None or pairs == []:
                    if sharing.get("Status") != 200:
                        continue
                    raise ValueError("successful DevGPT sharing has no turns")
                if not isinstance(pairs, list):
                    raise ValueError("malformed DevGPT turns")
                messages = []
                for pair in pairs:
                    if not isinstance(pair, dict) or "Prompt" not in pair or "Answer" not in pair:
                        raise ValueError("malformed DevGPT pair")
                    messages.extend([{"role": "user", "content": pair["Prompt"]},
                                     {"role": "assistant", "content": pair["Answer"]}])
                result.append(messages)
        if not result:
            raise ValueError("no available DevGPT conversations")
        return result
    if format == "sharegpt":
        records = [root] if isinstance(root, dict) else root
        if not isinstance(records, list) or not records:
            raise ValueError("ShareGPT requires conversation records")
        result = []
        for record in records:
            if not isinstance(record, dict) or not isinstance(record.get("conversations"), list):
                raise ValueError("malformed ShareGPT conversation")
            messages = []
            for message in record["conversations"]:
                if not isinstance(message, dict) or not {"from", "value"} <= message.keys() <= {"from", "value", "status"}:
                    raise ValueError("unsupported ShareGPT message")
                messages.append({"role": message["from"], "content": message["value"],
                                 "status": message.get("status", "complete")})
            result.append(messages)
        return result
    if _message_array(root):
        return [root]
    if isinstance(root, dict):
        records = [root]
    elif isinstance(root, list) and root:
        records = root
    else:
        raise ValueError("OpenAI input requires messages or conversation records")
    result = []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("malformed conversation record")
        keys = [key for key in ("messages", "conversation") if key in record]
        if len(keys) != 1 or not isinstance(record[keys[0]], list):
            raise ValueError("ambiguous or missing message array")
        result.append(record[keys[0]])
    return result


def _https(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("source URL must be HTTPS without credentials")
    return url


class _HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        _https(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def _download(url):
    _https(url)
    opener = urllib.request.build_opener(_HTTPSRedirect())
    with opener.open(url, timeout=30) as response:
        raw = response.read(MAX_INPUT_BYTES + 1)
    if not 0 < len(raw) <= MAX_INPUT_BYTES:
        raise ValueError("download exceeds document limit")
    return raw


def summary(messages, selection):
    return {"selection": selection, "messages": len(messages),
            "user_messages": sum(m["role"] == "user" for m in messages),
            "assistant_messages": sum(m["role"] == "assistant" for m in messages),
            "source_bytes": sum(len(m["content"].encode("utf-8")) for m in messages),
            "maximum_message_bytes": max(len(m["content"].encode("utf-8")) for m in messages)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input", type=Path, help="local JSON or JSONL")
    source.add_argument("--url", help="explicit public HTTPS JSON or JSONL download")
    parser.add_argument("--format", choices=FORMATS, default="auto")
    parser.add_argument("--list", action="store_true", help="print content-free sizes, without importing")
    parser.add_argument("--select", type=int, default=0, help="zero-based conversation index")
    parser.add_argument("--destination", type=Path, help="new isolated store; existing parent required")
    parser.add_argument("--through-message", type=int, help="import a prefix ending at a whole message")
    parser.add_argument("--dataset", default="public-chat")
    parser.add_argument("--source-url", help="HTTPS provenance URL for a local file")
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/boros/Boros.app/Contents/MacOS/Boros")
    parser.add_argument("--open", action="store_true", help="launch Boros with the imported isolated store")
    args = parser.parse_args(argv)
    if args.select < 0 or args.through_message is not None and args.through_message <= 0:
        parser.error("selection must be nonnegative and prefix count positive")
    if args.list and (args.destination or args.open or args.through_message):
        parser.error("--list cannot import, truncate, or open a store")
    if not args.list and args.destination is None:
        parser.error("--destination is required for import")
    try:
        raw = _download(args.url) if args.url else _read(args.input)
        original = _parse(raw)
        chats = conversations(original, args.format)
        if args.list:
            for index, chat in enumerate(chats):
                print(json.dumps(summary(normalize(chat), index), sort_keys=True))
            return 0
        if args.select >= len(chats):
            raise ValueError("selection is outside the source")
        messages = dated_messages(original, chats[args.select], raw)
        if args.through_message is not None and args.through_message > len(messages):
            raise ValueError("prefix is outside the conversation")
        address = args.source_url or args.url
        if address:
            _https(address)
        if not isinstance(args.dataset, str) or not 0 < len(args.dataset.encode()) <= 256:
            raise ValueError("invalid dataset name")
        document = {"schema_version": 2 if any("source_time" in m for m in messages) else 1, "title": "Imported test chat",
                    "source": {"dataset": args.dataset, "url": address,
                               "sha256": hashlib.sha256(raw).hexdigest(), "selection": args.select},
                    "messages": messages, "original_json": raw.decode("utf-8")}
        encoded = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if len(encoded) > MAX_INPUT_BYTES:
            raise ValueError("normalized source exceeds document limit")
        binary = args.binary.resolve(strict=True)
        # Resolve the parent only: resolving the final component could follow
        # an existing symlink and turn a refused destination into another path.
        destination = args.destination.absolute()
        if ".." in destination.parts:
            raise ValueError("destination contains parent traversal")
        destination = destination.parent.resolve(strict=True) / destination.name
        if os.path.lexists(destination):
            raise ValueError("destination already exists")
        with tempfile.TemporaryDirectory(prefix="boros-chat-input-") as directory:
            prepared = Path(directory).resolve() / "chat.json"
            descriptor = os.open(prepared, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(encoded)
            command = [str(binary), "--import-chat", str(prepared), "--destination", str(destination)]
            if args.through_message is not None:
                command.extend(["--through-message", str(args.through_message)])
            run = subprocess.run(command, capture_output=True, timeout=300)
            if run.returncode:
                # Native errors are already content-free, but use a fixed
                # wrapper error so a wrong supplied binary cannot leak text.
                raise ValueError("native import failed")
            report = json.loads(run.stdout)
            expected = {"status", "messages", "user_messages", "assistant_messages", "source_bytes", "import_sha256"}
            if not isinstance(report, dict) or set(report) != expected or report["status"] != "verified":
                raise ValueError("invalid native receipt")
            if report["import_sha256"] != hashlib.sha256(encoded).hexdigest():
                raise ValueError("native receipt digest mismatch")
            imported = messages[:args.through_message] if args.through_message is not None else messages
            totals = summary(imported, args.select)
            for key in ("messages", "user_messages", "assistant_messages", "source_bytes"):
                if type(report[key]) is not int or report[key] != totals[key]:
                    raise ValueError("native receipt inventory mismatch")
            print(json.dumps(report, sort_keys=True))
        if args.open:
            subprocess.Popen([str(binary)], env={**os.environ, "BOROS_DATA_DIR": str(destination)},
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        return 0
    except (OSError, ValueError, TypeError, RecursionError, subprocess.SubprocessError):
        print("Chat import could not complete. Check the source format, message limits, selection, built binary, and new destination.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
