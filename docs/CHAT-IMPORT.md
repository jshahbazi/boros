# Public chat ingestion for long-history tests

`scripts/import_chat.py` converts an established public text conversation and uses Boros's native `--import-chat` command to publish a fresh, private application store. Open that store to ask follow-up questions through normal context preparation, retrieval, admission, and the local model.

This offline development importer creates stored source events without generating answers or inventing answering episodes, usage, or invocation records. Boros's recent-history, historical-evidence, provider, and episode limits still govern each new question. Import success establishes storage integrity; it supplies no measured claim about answer quality.

## Build and load BEAM

```sh
python3 scripts/build.py
mkdir -p "$HOME/Library/Application Support/Boros Test Chats"

python3 scripts/import_chat.py \
  --url https://raw.githubusercontent.com/mohammadtavakoli78/BEAM/main/chats/500K/1/chat.json \
  --format beam --dataset BEAM \
  --destination "$HOME/Library/Application Support/Boros Test Chats/BEAM-500K-1" \
  --open
```

The destination must be new. `--open` launches the built binary with `BOROS_DATA_DIR` pointing to the imported store. The conversation uses project `default` and appears in the existing chat picker. Follow-up answers use the app's local server settings; optional credentials remain in Keychain. Semantic indexing starts under the existing background budget when the GUI opens. The importer builds the lexical index without running an encoder.

[BEAM](https://github.com/mohammadtavakoli78/BEAM) provides generated conversations in nominal 128K, 500K, 1M, and 10M token sets. Its repository names the smallest directory `100K`. The dataset includes coding and other domains; this example is a general benchmark conversation, not a verified coding-only sample. The [benchmark/data license](https://github.com/mohammadtavakoli78/BEAM#license) is CC BY-SA 4.0. Follow its attribution and sharing terms when redistributing data or derivatives. No dataset payloads are checked into Boros.

The tool reports exact UTF-8 bytes and message counts. It does not estimate tokens: a corpus's nominal size and a provider's tokenizer count are different quantities. `--through-message 300` imports the first 300 messages at original message boundaries, without splitting, summarizing, repeating, or padding. Record the chosen prefix when interpreting results. A prefix may end on a user message.

## Local files and conversation selection

Inspect available conversations without showing their text:

```sh
python3 scripts/import_chat.py --input /absolute/path/chats.json --format auto --list
```

Each output row includes a zero-based `selection`, role counts, total source bytes, and maximum message bytes. Select one conversation:

```sh
python3 scripts/import_chat.py \
  --input /absolute/path/chats.json --format auto --select 12 \
  --dataset DevGPT --source-url https://github.com/NAIST-SE/DevGPT \
  --destination "$HOME/Library/Application Support/Boros Test Chats/DevGPT-12" \
  --open
```

`--binary /absolute/path/to/Boros` chooses another build. `--url` downloads an explicitly supplied HTTPS source without embedded credentials; redirects must remain HTTPS. Local conversion needs only Python's standard library. The CLI prints fixed errors and aggregate metadata, never source text, titles, URLs, or provider responses.

## Supported formats

| Format | Input | Mapping |
|---|---|---|
| OpenAI style | Message array; object with `messages` or `conversation`; array/JSONL of those objects | `role`, string `content`, optional `status` |
| ShareGPT | Object or array/JSONL of objects with `conversations` | `from: human/gpt`, string `value` |
| BEAM repository | Ordered batches with `turns`, each an ordered message array | One chat in original batch/turn/message order |
| DevGPT | `Sources` with `ChatgptSharing`, a source record, or source-record array | Each available `Conversations` array becomes one chat; `Prompt` is user, `Answer` is assistant |

DevGPT preserves file/pair order. Unavailable shares with no conversation and a non-200 status are excluded from selection. Available shares with malformed or missing prompt/answer sides fail validation. `--list` validates every listed chat. Import validates every message in the selected chat, including those beyond a requested prefix. Check DevGPT's source licensing before redistribution; Boros supplies no new license for imported data.

Only text user/assistant roles become source events. `human` and `gpt` are explicit aliases. System, developer, tool, function, multimodal blocks, and invocation fields are rejected. Raw SWE-chat traces, ChatGPT account exports with branch mappings, and Hugging Face Parquet are unsupported; obtain a supported JSON export first. Embedded instructions remain source material and cannot replace Boros's host instructions.

Message text retains exact UTF-8 bytes, whitespace, original order, role, and explicit `complete`, `partial`, `failed`, or `cancelled` capture status. Missing status defaults to `complete`, meaning the source text was fully imported; it does not establish that the original generation finished successfully. Role alternation is not enforced. Event timestamps record ingestion. Original timestamps, IDs, BEAM batch metadata, and DevGPT code representations remain in the private source file; they do not become searchable event fields. Temporal evaluations requiring batch time anchors need a future adapter contract.

## Publication and provenance

The converter reads strict UTF-8 JSON/JSONL and rejects duplicate keys and nonfinite numbers. Native ingestion independently validates the canonical schema, duplicate keys, sizes, roles, and statuses. Each message must fit the existing 4 MiB event bound; oversize messages fail without truncation. Limits are 100,000 messages per selected chat and 128 MiB per original/canonical document. Embedding the original document means conversion can hit the canonical cap before the original-file cap.

Ingestion uses a private sibling staging directory and `MemoryStore` APIs. It closes and reopens the owner, then compares every message's bytes, digest, role, status, and order before syncing files and publishing with an atomic exclusive rename. Existing destinations are never overwritten. The native destination parent must exist without symlink components. Normal failures remove unpublished staging. Process death can leave a private `.boros-import-*` folder, with the final destination absent. A parent sync failure after rename reports unknown publication durability and retains the completed destination.

The private destination contains:

- `memory.sqlite3`: imported events and lexical index for normal retrieval.
- `chat-source.json`: exact original file, including metadata and potentially other chats from the input corpus.
- `chat-import.json`: canonical native input retaining the complete selected chat even for a prefix import.
- `import-manifest.json`: source provenance, selection, event/turn IDs, per-message hashes, sizes, statuses, and timestamp interpretation.

Directories use mode 0700 and files mode 0600. The manifest records whether original source bytes were supplied and hash-verified. A direct canonical native input may omit `original_json`, leaving its source declaration unverified. Existing Boros backups preserve database sources and journals but omit these importer sidecars; retain them separately when preserving an experiment. Runtime data belongs outside Git.

## Native command and checks

The canonical version-1 document has `schema_version`, `title`, `source` (`dataset`, optional `url`, original-file `sha256`, `selection`), `messages` (`role`, `content`, `status`), and optional `original_json`.

```sh
.build/boros/Boros.app/Contents/MacOS/Boros \
  --import-chat /absolute/path/canonical.json --destination /absolute/path/new-store

BOROS_IMPORT_BINARY="$PWD/.build/boros/Boros.app/Contents/MacOS/Boros" \
  python3 scripts/test_chat_import.py
```

Checks use synthetic fixtures and temporary stores. Official benchmark questions, gold answers, scoring, provider token feasibility, repeated history comparisons, and registered benchmark reports require a separate answering harness and the original benchmark protocol.

## October 5, 2026 development evidence

The native application built successfully. The existing 1,673 application checks passed, and the final focused importer suite passed 12 tests with no skips. Importer checks include Python-to-native JSONL selection, exact Unicode/whitespace and role/status preservation, duplicate keys including escaped spellings, unsupported roles/fields, oversized messages, invalid later messages during prefix selection, source hash mismatch, refused destinations, source provenance, reopened SQLite readback, and a real SIGKILL during unpublished staging.

The official BEAM `chats/500K/1/chat.json` imported 796 messages: 398 user and 398 assistant, totaling 1,861,956 message-text bytes. Separate read-only checks confirmed all 796 payloads, digests, roles, statuses, lexical-index rows, source-file hashes, and private directory mode. These results establish this corpus's ingestion integrity. Its exact provider token count and answer quality were not measured. Dataset payloads and the resulting application store remain outside the repository.
