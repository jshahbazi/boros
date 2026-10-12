# Boros

**A framework for handling very long conversations.**

Boros preserves complete conversation sources, retrieves relevant passages, and assembles bounded model context with source provenance and durable work accounting. It is built for histories that outgrow a model's context window.

The framework keeps original messages in SQLite and records which source ranges reach each model request. Retrieval, token admission, streaming, and interrupted requests have explicit budgets and recovery paths. Its evaluation tools measure source recovery and answering behavior on long histories.

The native macOS chat app is a reference integration and an easy way to test the framework end to end. Import and diagnostic tools provide additional ways to exercise it with existing conversation histories.

**Status: early developer preview.** The current implementation consists of Swift modules embedded in the test app and diagnostic tools. A published standalone library and stable external API remain integration work. Retrieval can miss relevant evidence, and representative answer quality remains unproven.

## Framework capabilities

- **Durable source history:** complete accepted UTF-8 text, stable source IDs, digests, and capture status in SQLite. Prompt and preview limits preserve the stored originals.
- **Scoped retrieval:** literal and FTS5 lexical search, exact source paging, and bounded archive excerpts alongside recent messages. The reference Send path uses lexical retrieval.
- **Context assembly and admission:** separate recent-history and evidence limits, complete request provenance, and response-capacity reservations. The verified Qwen adapter counts the fully rendered prompt with the server's tokenizer.
- **Work accounting and recovery:** retrieval and answering share durable allowances and deadlines. Accepted inputs commit before dispatch; received chunks commit before display. Interrupted attempts retain incomplete status and incurred work.
- **Import and backup:** verified backup/restore and offline ingestion of BEAM, DevGPT, ShareGPT, and user/assistant message JSON.
- **Evaluation tooling:** isolated source-recovery diagnostics, answering comparisons, and synthetic checks for storage, retrieval, admission, and recovery contracts.

Semantic search, exchange-index selectors, and multi-stage memory investigation are available through explicit experimental or evaluation paths; they have separate evidence and limitations.

## Test the framework

The reference app provides a Swift/AppKit interface with streaming, Stop, saved drafts, a chat picker, a source browser, and Markdown answer rendering with inline math. It exposes the framework's storage and answering paths through a simple chat workflow.

The instructions below build this test harness. Its current verified inference integration supports one specific model/server combination.

### Requirements

- An Apple silicon Mac.
- macOS 14 or newer to build the reference app. The verified inference server has a higher requirement: [mlx-serve v26.10.1 requires macOS 26.2 or newer](https://github.com/ddalcu/mlx-serve/blob/v26.10.1/README.md#get-started).
- Xcode Command Line Tools with Swift, Python 3, and Git. The current build uses system frameworks and SQLite; no Python packages are required.
- A running local model server for generating replies. Boros does not bundle or download model weights.

### 1. Start the supported model server

The verified text adapter supports [mlx-serve v26.10.1](https://github.com/ddalcu/mlx-serve/releases/tag/v26.10.1) with this exact served model:

```text
ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit
```

**Check the hardware requirement before downloading.** The [model card](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit) reports roughly 75 GB of resident memory plus KV cache and measurements on a 128 GB Mac. These figures describe the current model-serving setup.

Install the pinned server release using its upstream instructions, then serve the model:

```sh
mlx-serve --model ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit --serve
```

Boros defaults to `http://localhost:11234/v1/` and the model ID above. In Show settings, confirm API address and Served model, then click Save API settings. An optional API key is stored in macOS Keychain.

Unknown model IDs, chat templates, or server versions fail admission visibly. An OpenAI-compatible API alone does not establish compatibility. Existing native GGUF profiles are experimental; their exact input-token admission and model/runtime identity remain unverified. See [the provider contract](docs/PROVIDER-ADMISSION.md) before changing the inference setup.

### 2. Build the test app

```sh
git clone https://github.com/jshahbazi/boros.git
cd boros
python3 scripts/build.py --open
```

The build produces `.build/boros/Boros.app` and launches it. The test app is locally ad-hoc signed.

### 3. Exercise conversation memory

Send messages, use New Chat to start another conversation, and reopen previous chats with the chat picker. Search Memory lets you find and inspect original messages. The harness uses one local user and the `default` project scope.

To retain custom instructions, open Show settings, edit System, and click Save instructions. Unsaved edits apply in the current window; the explicit save makes them persist. Saved instructions apply to future requests across chats in the local store.

To test a long existing history, use [chat import](docs/CHAT-IMPORT.md) to load a supported conversation into a separate store, then ask follow-up questions in the harness. The [offline imported-chat diagnostic](docs/IMPORTED-CHAT-EVALUATION.md) measures source recovery without generating answers.

File → Create Backup writes a verified archive. File → Restore Backup to New Folder creates a separate store. See [backup and restore](docs/BACKUP-RESTORE.md) for archive contents and CLI commands.

## How memory works

Each accepted message becomes an original source record with an ID, complete UTF-8 payload, digest, and capture status. The context builder keeps the current request, selects recent messages, and searches older sources within the current project scope. Ordinary Send uses SQLite FTS5 lexical matching; it performs no query embedding or semantic-index read.

The selected Qwen path renders and counts the complete candidate prompt before dispatch. Its journals link delivered historical ranges back to source records and retain work already incurred during retries, cancellation, and recovery. Prompt and preview limits do not truncate the stored source.

Source selection is inspectable; complete recall and correct answers remain unproven. The [implementation boundary](docs/IMPLEMENTATION.md) describes the contracts in detail.

## Data and privacy

Chats, drafts, saved instructions, and durable journals live under `~/Library/Application Support/Boros`. `BOROS_DATA_DIR` selects another store for development or imported histories. The chat database and saved instructions are unencrypted local data; backups include the saved instructions.

The application's HTTP inference adapter accepts loopback destinations only and rejects redirects. Credentials use macOS Keychain and are excluded from chat storage and backups. Boros performs no external tool actions. Your model server is a separate process with its own configuration and behavior.

Research tools have a separate scope: some download public datasets or call hosted evaluation providers when explicitly run. Consult each tool's documentation before using it. Runtime histories, credentials, model weights, and generated bundles stay outside Git.

## Current limits and next work

The current framework implementation and reference harness target text conversations on a single-user macOS store. Standalone library packaging, a stable external API, a multi-client or MCP service, scoped task/policy controls, deletion and retention workflows, and production summary-tree browsing remain unfinished or gated. The harness schedules no background semantic indexing under its current policy; a remote inference adapter for it remains unimplemented.

Development evaluations expose source-selection and answering failures. Representative recall, citation correctness, abstention, full interaction latency, and total cost have not met the project's release gates. Test counts and retrieval-only timings do not establish those results.

Current work focuses on improving evidence selection and measuring the answering path before promoting experimental memory strategies. See [status and measured results](docs/STATUS.md), [the design repair plan](docs/DESIGN-REPAIR-PLAN.md), and [the evaluation specification](docs/EVALUATION.md) for the framework's roadmap and decision gates.

## Development and contributions

The framework's current Swift modules and AppKit reference app live in `Sources/Boros`. They compile into one executable today. Python scripts provide builds, synthetic contract checks, import, and evaluation tooling.

Run the developer check suite from the repository root:

```sh
python3 scripts/check.py
```

It builds the app, runs synthetic checks in isolated stores, and checks the Swift subsets used by standalone tools. Checks that require pinned dataset/tokenizer artifacts report a skip when those dependencies are absent. Real-model evaluations are separate workflows; follow their declared inputs, accounting, and execution controls.

Useful contributions include reproducible failures on long histories, retrieval and context strategies, model adapters with exact token-count verification, evaluation improvements, and library/API integration work. For bug reports, include the commit, macOS version, hardware, model/server versions, and a minimal synthetic reproduction. Keep private conversation text and credentials out of issues, logs, and patches.

Read [AGENTS.md](AGENTS.md) and [the implementation boundary](docs/IMPLEMENTATION.md) before extending a feature. Open an [issue](https://github.com/jshahbazi/boros/issues) for design discussion or submit a focused pull request with appropriate verification.

## Design and provenance

The [architecture plan](tracechat-plan.md) and [independent design review](tracechat-adversarial-review.md) preserve the original design evidence under the historical name TraceChat. The initial AppKit chat interface came from the author's earlier [mcpme experiment](docs/GUI-ORIGIN.md).

## License

Boros-authored code is licensed under the [MIT License](LICENSE).

Third-party materials retain their own terms, including the [Qwen chat-template license](Tests/qwen38-chat-template.LICENSE) and the notices in [licenses/models](licenses/models). Model weights and datasets are not included; obtain them under their respective licenses. The [provider provenance notes](docs/PROVIDER-ADMISSION.md#third-party-template-provenance) document the template's separate license.
