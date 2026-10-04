# GUI provenance

The user requested reuse of the native chat GUI developed in the Codex chat `01a104ba-7f6a-79a0-be11-e3a657997d89`, titled “Assess a small onboarding model (2).”

The initial import came from:

- Repository: `https://github.com/jshahbazi/mcpme`
- Branch: `codex/bonsai-benchmark`
- Commit: `3e58f8528e4e462d102614403d39bcea33479f6c`
- Source directory: `experiments/bonsai_playground`

Imported source files: `BonsaiPlayground.swift`, `Conversation.swift`, `ModelProfiles.swift`, `ModelRunner.swift`, `ReasoningRunner.swift`, `SystemPromptEditor.swift`, and `build.py`.

The import contains source code, the model provenance manifest, and the existing model-license texts. It contains no model weights, generated bundles, chat history, or credentials. The inherited model manifest is preserved at [imported-model-provenance.md](imported-model-provenance.md). Its historical test results describe the source experiment, not Boros verification.

Reuse was explicitly requested by the repository owner. The inspected source revision has no repository-root `LICENSE`; `templates/LICENSE` is a project-generation template and does not establish a source-code license. Model-license files apply to their named artifacts. No model redistribution or new project-wide license is implied by this import.

The original OptChat repository's three planning commits are ancestors of the Boros implementation branch. The independent review continues to refer to its reviewed historical revision and line numbers.

The original checkout was moved to `.migration/optchat-original` inside Boros as a reversible local migration backup. That directory is ignored. The active planning documents and their complete commit history are in the Boros branch.
