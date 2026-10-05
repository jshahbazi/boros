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

The current page protocol (`search-agreement-round-robin-v2`) puts sources found by both search paths first, in lexical rank order. Distinct lexical and literal windows in one source are retained. It reads each candidate's hit window before spending remaining allowance on source tails, under the same 12,000 returned-byte and 19-page-call caps. This changes the page scheduling protocol from the initial source-by-source diagnostic; page scores from those two versions must identify that change.

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

Per-span `goldDiagnostics` are computed after the read episode finishes. They record the imported-message ordinal, expected byte range, delivered ranges, coverage, and a failure stage. Raw page attempts also record the expected source's candidate rank. These diagnostics never supply gold offsets to retrieval, change the query, or direct page reads. Query text and source text remain absent from reports.

## Semantic and accounting limits

Semantic indexing defaults to `--semantic-chunks 4096` and `--index-seconds 60`. It uses the installed Apple NaturalLanguage sentence embedding only; it does not download assets or use Qwen. Background indexing is subject to the store's durable budget. Partial, unsupported, failed, or unavailable semantic coverage remains explicit in search manifests and falls back to lexical/original-source retrieval. Set `--semantic-chunks 0` to disable indexing; the hybrid protocol is then reported as skipped.

The chunk flag bounds requested worker capacity; published records and failed attempts are reported separately. The time flag stops scheduling new batches; an already-started batch can finish afterward. `semanticIndex.status: available` establishes initialization, not complete corpus coverage. Each hybrid probe records pending/unsupported/failed sources, indexed bytes/chunks, hole truncation, and query disposition. New diagnostic stores have fresh maintenance ledgers; these runs do not measure the original application's remaining background allowance. Apple encoder input tokens remain unknown in the authoritative receipts.

`semanticReportedHoleReasons` counts only the holes included in the bounded manifest. When `holesTruncated` is true, these counts are a subset of unsupported ranges and must not be treated as corpus totals.

Context preparation uses byte bounds of 65,536 serialized context bytes, 24,000 recent bytes, and 12,000 evidence bytes. The runner does not perform staged Qwen token counting, provider admission, or answer generation. Results are unregistered diagnostics and must not be presented as official benchmark or model-quality evidence. No measurements are asserted here; inspect the generated report and its coverage fields for the actual run.

The harness copies and hashes its source dependencies before compilation and uses the application's `-O -swift-version 5 -parse-as-library` settings. Reports identify the captured code, including uncommitted edits. Fixed protocol order warms later attempts; a process restart does not clear the operating system's disk cache. Whole-store verification runs before and after the probes. Gold scoring and returned-range verification occur after read-episode terminalization; recent-message delivery checks add diagnostic work inside the selection timer. These timers do not establish product latency. Original import IDs, roles, statuses, turn IDs and text are retained; diagnostic store timestamps record reingestion and cannot establish original chronology.

The contract check command is:

```sh
python3 scripts/test_imported_chat_evaluation.py
```

## October 5, 2026 development evidence

The focused suite passed 9 tests, and the integrated development-app check passed 1,694 checks. Contracts cover exact source bytes/roles/statuses, a read-only committed snapshot, exclusion of later application turns, private reports, refused replacement, corrupt source/canonical rejection, strict UTF-8 gold spans, restart, local-read origins, zero-budget failures, and scoring that excludes current-prompt echoes and identical text in the wrong event.

The imported BEAM conversation supplied 796 messages and 1,861,956 text bytes. The default optimized run evaluated 12 source-derived answerable phrase probes plus one absence probe in warm and process-restart profiles. All 104 read attempts completed, original diagnostic sources verified before and after both profiles, and all authoritative receipts recorded zero HTTP attempts. Captured dependency hashes matched the evaluated working-tree files. The private metadata report is `.build/evaluation/imported-beam-offline-20261005-optimized.json`; dataset payloads and diagnostic stores remain outside Git.

| Protocol | Required spans recovered, warm | Required spans recovered, process restart |
|---|---|---|
| Recent-only context | 1/12 | 1/12 |
| Lexical context | 8/12 | 8/12 |
| Hybrid context | 8/12 | 8/12 |
| Exact source pages | 10/12 | 10/12 |

The absence probe returned no raw-search hits. The semantic sidecar finished processing all 796 sources: 51 complete and 745 unsupported, with no pending or failed sources. It recorded 118 supported vector chunks and 2,117 unsupported chunks; its hole list reached the 128-entry reporting cap. Full semantic coverage was false. Hybrid initialization and processing therefore supplied limited usable embeddings on this corpus. These targeted diagnostics do not establish natural-question recall, answer accuracy, or an official BEAM score. The exact-page path was slow in this run; its process-restart diagnostic p95 was about 95 seconds. OS cache and system load were uncontrolled, and timers include diagnostic work, so this is not a product latency estimate.

## Failure trace and retrieval corrections

The private pre-fix trace is `.build/evaluation/beam-failure-trace-before-20261005.json`. It reuses the original automatic probe digest, `b3eb4bc6297798c2a856dd82e845814a808129defb5216d272030beae1557b7b`, with semantic indexing disabled for a focused warm run.

| Probe ordinal | Path | Observed omission |
|---|---|---|
| 3 | Lexical context | Gold bytes 219–315; delivered bytes 664–1224 of the correct message |
| 5 | Lexical context | Gold bytes 2364–2461; delivered bytes 1715–2275 of the correct message |
| 8 | Lexical context | Gold bytes 172–273; delivered bytes 345–905 of the correct message |
| 10 | Lexical context | Gold bytes 2050–2157; delivered bytes 662–1222 of the correct message |
| 7 | Exact pages | Correct source ranked 9th; no page delivered before the byte allowance filled |
| 9 | Exact pages | Correct source ranked 10th; no page delivered before the byte allowance filled |

The byte intervals above are half-open UTF-8 ranges. Metadata-only inspection of the original scoped FTS ranking placed the four missed lexical sources at ranks 1, 1, 1, and 2. The returned excerpts centered on the first matching request word, leaving the intended cluster outside the delivered window.

Production metered and unmetered lexical retrieval now share a bounded excerpt selector. It considers the first occurrence of each distinct term, selects the 560-character window with the most complete term matches, breaks ties by matched bytes and earliest start, and caps the exact UTF-8 excerpt at 4,096 bytes. Literal search retains its first exact match. Metered lexical reads reserve `source_bytes × (3 + 3 × query_term_count)` before loading: materialization, digest, per-term search/window walks, and final excerpt materialization. The higher conservative charge can reach a resource frontier earlier; it never renews the episode allowance. The semantic ranking fingerprint includes the new excerpt contract; embeddings and support guards are unchanged.

The selector inspects first occurrences rather than every repeated occurrence. Candidate, evidence, page and semantic coverage limits remain. Correcting these omissions does not establish general developer-chat recall or model answer quality.
