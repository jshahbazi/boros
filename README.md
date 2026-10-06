# Boros

Boros is a native macOS chat application with durable conversational evidence and source retrieval. It starts from the chat GUI built in the user's mcpme experiment and the reviewed TraceChat architecture.

The native foundation is implemented. It targets one local user, text conversations, an explicit project scope, and a local OpenAI-compatible model server. Start with [status and roadmap](docs/STATUS.md) for the feature inventory, measured results, unfinished plans and dependency-ordered next work. The complete architecture is in [the plan](tracechat-plan.md), with detailed boundaries and verification in [implementation status](docs/IMPLEMENTATION.md).

## Build

Requirements: Apple silicon, macOS 14 or newer, Xcode Command Line Tools with Swift, and Python 3. No model weights or Python packages are bundled.

```sh
python3 scripts/build.py
```

The build produces `.build/boros/Boros.app`. Use `--open` to launch it after building. The app is locally ad-hoc signed; this is a development build.

## Local model

The user selected the [Qwen3.8 Flash Next MLX model](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit). The default mlx-serve API address is `http://localhost:11234/v1/`; the server must be running for inference. Credentials are optional and use macOS Keychain. Boros verifies the selected model's complete prompt token count before dispatch, reserving response tokens and a safety margin within the API token budget.

The verified API adapter currently supports this Qwen text template on mlx-serve 26.10.1. Changing the model, template or server version requires adapter verification; unsupported combinations fail visibly. See [provider admission](docs/PROVIDER-ADMISSION.md) for compatibility, template provenance and license details. Existing native GGUF profiles remain available with their runtime context controls.

Server connectivity and model-quality validation are separate checks. A successful response establishes integration, not reliable memory, instruction following, or task performance.

## Development

The native interface preserves the earlier editor, scrolling transcript, streaming, cancellation, and keyboard controls. The foundation adds a local SQLite evidence store and independent source retrieval. Tests use synthetic conversations and temporary stores.

```sh
python3 scripts/check.py
python3 scripts/test_memory.py
python3 scripts/test_episode.py
python3 scripts/test_local_read.py
python3 scripts/test_authority_bindings.py
python3 scripts/test_background_index.py --full-source
python3 scripts/test_semantic_recovery.py
python3 scripts/test_backup.py
python3 scripts/test_evaluation.py
BOROS_IMPORT_BINARY="$PWD/.build/boros/Boros.app/Contents/MacOS/Boros" python3 scripts/test_chat_import.py
python3 scripts/test_imported_chat_evaluation.py
python3 scripts/test_answer_evaluation.py --binary "$PWD/.build/boros/Boros.app/Contents/MacOS/Boros"
python3 scripts/test_answer_rubrics.py
python3 scripts/test_developer_answer_evaluation.py
python3 scripts/test_evidence_controls.py
```

Use New Chat to start another retained conversation, the chat picker to reopen one, and Search Memory to inspect source events. The initial UI uses the `default` project. Chats and drafts are saved under `~/Library/Application Support/Boros`; `BOROS_DATA_DIR` selects an isolated store for development.

To keep instructions after restart, open Show settings, edit System, and click Save instructions. The saved text applies to future requests in all chats in that local store, across model profiles. Clear the field and save to remove custom instructions. Unsaved edits apply to requests in the current window; changing another setting does not save them. The save limit is 128 KiB of UTF-8. Saved instructions are private text in `settings.json` and are included in backups. Scoped project/task preferences remain unfinished.

For JSON output from the selected Qwen API model, select JSON object under API output and specify the desired fields in your question. JSON mode turns thinking off. The option defaults to off and is saved with API settings or Send. Boros retains the complete response and reports when it is not a valid object. JSON mode does not guarantee correct answers or citations. Its extra prompt instruction is included in token admission and accounting; see [the provider contract](docs/PROVIDER-ADMISSION.md#optional-json-object-output).

For long public histories, [the chat importer](docs/CHAT-IMPORT.md) loads BEAM, DevGPT, ShareGPT, or role-message JSON into a new private test store. It preserves exact source text and roles, verifies explicit OpenAI message timestamps against the original artifact, verifies complete readback before publication, and can open the imported chat for normal follow-up questions.

With the answering model stopped, [the offline imported-chat runner](docs/IMPORTED-CHAT-EVALUATION.md) compares recent-only, lexical, hybrid, and exact-page source recovery in disposable stores. It reports source coverage, read-episode resources, semantic holes and timing without printing chat text or generating answers.

The [production answering diagnostic](docs/ANSWER-EVALUATION.md) compares recent-only and hybrid through the same selected-Qwen coordinator as ordinary GUI Send. It compiles a copied source snapshot and runs all probes from one fixed public development history in separate restored stores. The report contains metadata, accounting, delivered-source coverage and literal factual scores; transient answers are discarded after scoring. With the configured model server running:

```sh
python3 scripts/evaluate_answers.py --output .build/evaluation/public-answer-pilot.json
```

The output must be new. Validation/held-out data, arbitrary corpus/store paths and oracle fields are refused. The diagnostic does not establish representative quality, semantic correctness of prose, provider feasibility, or the full five-category evaluation gate.

The [public developer-history amendment](docs/DEVELOPER-ANSWER-EVALUATION.md) adds three pinned DevGPT histories and 24 paired attempts, with frozen exact-quote, cross-message, citation and abstention scoring. It requires the exact pinned public source file and uses separate oracle-free native projections. Its source-derived questions, chronology and code-placeholder limits remain explicit; representative reasoning and broader provider-feasibility evidence are pending.

The [separate sufficient-evidence control](docs/EVIDENCE-CONTROL.md) supplies nine frozen complete original exchanges to the existing recent-only answering path. It verifies the entire pack and actual source/body/count receipts before reporting conditional reproduction/citation results. All nine packs were delivered and validated; Qwen passed 5/9 tasks. Its curated packs remain separate from paired retrieval inputs; all failures retain their declared denominator.

The [LongMemEval complete-source controls](docs/LONGMEMEVAL-SOURCE-CONTROLS.md) supply six frozen original-source packs through the counted answering path. They retain complete histories and questions, independently verify actual full-source delivery, and keep incomplete answers in the denominator. The six-control QA contract and representative quality evidence remain unfinished; current verification and execution results are in [STATUS.md](docs/STATUS.md).

Accepted messages persist before dispatch; received answer chunks commit before display and interrupted attempts recover with an explicit incomplete status. Ordinary Send includes recent history and scoped lexical/semantic archive excerpts, excluding recent sources before candidate limits. Semantic retrieval uses an installed Apple English sentence encoder; unavailable or unsupported inputs retain lexical retrieval. Coverage gaps are recorded and surfaced. Search Memory provides scoped literal/lexical search and exact source pages.

File → Create Backup produces a verified archive of complete sources and durable journals. File → Restore Backup to New Folder creates a separate restored store. Command-line create/verify/restore is also available; see [backup and restore](docs/BACKUP-RESTORE.md). Credentials and the derived semantic sidecar are excluded; semantic indexing rebuilds under the archived background allowance when a restored store opens. File → Background Indexing Status shows maintenance accounting and why indexing has paused.

Answering and standalone reads share durable episode allowances and deadlines. Selected-Qwen recent context and evidence have independent token caps. Schema 5 adds global background-index limits across projects, retries and rebuilds, with conservative crash/restore accounting. Scoped lexical selection loads one bounded complete candidate at a time; literal scans use metered pages. Raw-work counters describe logical source work rather than physical disk I/O. Apple/native input tokens remain opaque. User-facing policy lifecycle, deletion, summary trees and external actions remain pending. Representative encoder and answering quality remain unproven. See [project status](docs/STATUS.md) and [implementation status](docs/IMPLEMENTATION.md) for verified boundaries.

## Local verification

The automated commands above use synthetic data and isolated stores. The [evaluation specification](docs/EVALUATION.md) freezes fixtures, splits, estimands and decision gates. Synthetic source coverage and arithmetic smoke tests do not establish general model quality or production cost/latency improvements.

See [GUI provenance](docs/GUI-ORIGIN.md), the [independent design review](tracechat-adversarial-review.md), and [implementation status](docs/IMPLEMENTATION.md).

The internal task/policy state foundation and its enforcement boundary are documented in [authority state](docs/AUTHORITY-STATE.md). Run the isolated content-free contract suite with `.build/boros/Boros.app/Contents/MacOS/Boros --authority-state-self-test`. The bounded clock contract is available through `--authority-clock-self-test` and `python3 scripts/test_authority_clock.py`. Schema-7 [authority bindings](docs/AUTHORITY-BINDINGS.md) add internal atomic task acceptance and conservative funded validation; `--authority-binding-self-test` checks them. Task and policy mutations remain unexposed while shared runtime gates are implemented.
