# Imported chat evaluation

`scripts/evaluate_imported_chat.py` runs an offline, unregistered retrieval diagnostic against one previously imported Boros conversation. It does not contact a model server or generate answers.

## Invocation

```sh
python3 scripts/evaluate_imported_chat.py \
  --store "$HOME/Library/Application Support/Boros Test Chats/BEAM-500K-1-20261005" \
  --output .build/evaluation/new.json
```

The output path must be new; reports are written with mode `0600`. Keep imported stores, probe files, and generated reports outside Git. The runner opens the original store read-only, verifies the import manifest and event digests, copies committed SQLite state into a private temporary directory, and re-ingests only the manifest-listed imported messages into a separate diagnostic store. Later application turns, runtime ledgers, existing vectors, and other conversations are excluded.

Use `--profile warm` for one process or the default `--profile both` for a warm run followed by a fresh-process restart using the retained diagnostic index. The runner evaluates four protocols: `recent_only`, `lexical_context`, `hybrid_context`, and `raw_pages`.

| Protocol | Measured path |
|---|---|
| `recent_only` | Whole recent messages, with no archive evidence |
| `lexical_context` | Boros's bounded automatic term selection and lexical evidence assembly |
| `hybrid_context` | The same helper with the installed Apple semantic sidecar |
| `raw_pages` | Explicit any-term lexical/literal search followed by bounded exact pages |

Each attempt owns a durable local-read episode. `--memory-operations 0` exercises budget failure; the default is 24. Failures retain their probe denominator and terminal receipt. A skipped hybrid attempt remains identified as unavailable. `coveredProbes / answerableProbes` describes only the selected diagnostic probes. `absenceProbesWithHits` applies to raw search; it does not measure a model's ability to abstain. A coverage-limit flag describes a bounded candidate window or index hole even when a particular gold span was recovered.

## Probes and scoring

Without `--probe-file`, the default is 12 answerable probes plus one absence probe. These are deterministic, corpus-derived phrase diagnostics that select rare terms from the imported text. They are targeted diagnostics, not natural questions, official benchmark scores, or independent recall evidence.

Private probes use this JSON shape:

```json
{
  "schema_version": 1,
  "import_sha256": "<digest of chat-import.json>",
  "probes": [
    {
      "prompt": "...",
      "query": "...",
      "literal": "...",
      "gold": [
        {"message": 0, "offset": 0, "bytes": 12, "sha256": "<span digest>"}
      ]
    }
  ]
}
```

`message` is a zero-based imported-message ordinal. `offset` and `bytes` are UTF-8 byte positions and lengths. `prompt` is limited to 16,384 UTF-8 bytes. `query` defaults to `prompt` and is limited to 1,024 bytes; supply it explicitly for a longer prompt. `literal` is optional. `query` and `literal` affect only `raw_pages`; context protocols derive terms from the complete prompt. Gold spans are validated against the imported event bytes before execution. A result is covered only when returned ranges from the expected event recover every required byte and SHA-256. Prompt text, a coincidental copy in another message, and prompt echoes do not count as evidence. Empty `gold` marks an expected-absence probe. Files allow 1–200 probes and up to 16 gold spans each.

## Semantic and accounting limits

Semantic indexing defaults to `--semantic-chunks 4096` and `--index-seconds 60`. It uses the installed Apple NaturalLanguage sentence embedding only; it does not download assets or use Qwen. Background indexing is subject to the store's durable budget. Partial, unsupported, failed, or unavailable semantic coverage remains explicit in search manifests and falls back to lexical/original-source retrieval. Set `--semantic-chunks 0` to disable indexing; the hybrid protocol is then reported as skipped.

The chunk flag bounds requested worker capacity; published records and failed attempts are reported separately. The time flag stops scheduling new batches; an already-started batch can finish afterward. `semanticIndex.status: available` establishes initialization, not complete corpus coverage. Each hybrid probe records pending/unsupported/failed sources, indexed bytes/chunks, hole truncation, and query disposition. New diagnostic stores have fresh maintenance ledgers; these runs do not measure the original application's remaining background allowance. Apple encoder input tokens remain unknown in the authoritative receipts.

Context preparation uses byte bounds of 65,536 serialized context bytes, 24,000 recent bytes, and 12,000 evidence bytes. The runner does not perform staged Qwen token counting, provider admission, or answer generation. Results are unregistered diagnostics and must not be presented as official benchmark or model-quality evidence. No measurements are asserted here; inspect the generated report and its coverage fields for the actual run.

The harness copies and hashes its source dependencies before compilation and uses the application's `-O -swift-version 5 -parse-as-library` settings. Reports identify the captured code, including uncommitted edits. Fixed protocol order warms later attempts; a process restart does not clear the operating system's disk cache. Whole-store verification runs before and after the probes. Gold scoring and returned-range verification occur after read-episode terminalization; recent-message delivery checks add diagnostic work inside the selection timer. These timers do not establish product latency. Original import IDs, roles, statuses, turn IDs and text are retained; diagnostic store timestamps record reingestion and cannot establish original chronology.

The contract check command is:

```sh
python3 scripts/test_imported_chat_evaluation.py
```
