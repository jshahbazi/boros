# Boros

Boros is a native macOS chat application with durable conversational evidence and source retrieval. It starts from the chat GUI built in the user's mcpme experiment and the reviewed TraceChat architecture.

The native foundation is implemented. It targets one local user, text conversations, an explicit project scope, and a local OpenAI-compatible model server. The complete architecture is in [the plan](tracechat-plan.md); workstream and milestone tables are in [project status](docs/STATUS.md), with detailed boundaries and verification in [implementation status](docs/IMPLEMENTATION.md).

## Build

Requirements: Apple silicon, macOS 14 or newer, Xcode Command Line Tools with Swift, and Python 3. No model weights or Python packages are bundled.

```sh
python3 scripts/build.py
```

The build produces `.build/boros/Boros.app`. Use `--open` to launch it after building. The app is locally ad-hoc signed; this is a development build.

## Local model

The user selected the already-running [Qwen3.8 Flash Next MLX model](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit). Boros connects to the local server rather than downloading or loading a second copy. The default API address is `http://localhost:11234/v1/`, with the selected Qwen model ID. Both are configurable in Settings. Authentication credentials are entered through the app and stored in macOS Keychain.

Server connectivity and model-quality validation are separate checks. A successful response establishes integration, not reliable memory, instruction following, or task performance.

## Development

The native interface preserves the earlier editor, scrolling transcript, streaming, cancellation, and keyboard controls. The foundation adds a local SQLite evidence store and independent source retrieval. Tests use synthetic conversations and temporary stores.

```sh
python3 scripts/check.py
python3 scripts/test_memory.py
```

Use New Chat to start another retained conversation, the chat picker to reopen one, and Search Memory to inspect source events. The initial UI uses the `default` project. Chats and drafts are saved under `~/Library/Application Support/Boros`; `BOROS_DATA_DIR` selects an isolated store for development.

Current limits: context admission counts serialized bytes, source search is synchronous, and semantic search, policy lifecycle, deletion, summary trees, and external actions are not implemented. See the implementation status for the full boundary.

See [GUI provenance](docs/GUI-ORIGIN.md), the [independent design review](tracechat-adversarial-review.md), and [implementation status](docs/IMPLEMENTATION.md).
