# Boros project status

Updated October 4, 2026. Implementation baseline: commit `2574b3b` on `codex/boros-foundation`.

The first native chat prototype is implemented. The complete architecture in the [plan](../tracechat-plan.md) remains in progress. This table reports available behavior and recorded verification; it does not estimate completion percentages or delivery dates.

| Workstream | Status | Available now | Remaining work |
|---|---|---|---|
| Project setup and design | Foundation complete | Migrated to Boros, retained planning history and adversarial review, committed and pushed the native foundation | Keep contracts and implementation status aligned as scope grows |
| Native chat GUI | Implemented | Chat picker, new chats, drafts, transcript restoration, streaming, cancellation, source browser | Final visual recheck after the last UI-control correction |
| Local model connection | Implemented | OpenAI-compatible mlx-serve connection at `http://localhost:11234/v1/`, selected Qwen model, structured role messages, optional thinking control | Broader compatibility and reliability evaluation |
| Transport and credentials | Implemented | Loopback-only endpoints, redirect rejection, bounded SSE parsing, explicit failure states, optional credentials in macOS Keychain | Any remote-provider support needs its own processing and disclosure contracts |
| Durable text history | Implemented for accepted text | Complete bounded UTF-8 payloads, typed events, stable IDs, digests, capture statuses, SQLite transactions and exclusive owner lock | Released-version migrations, attachments, and external payload protocol |
| Capture during generation | Partial | Human input commits before dispatch; assistant output commits on completion, cancellation, or reported failure | Incremental stream journaling and crash recovery for in-flight assistant fragments |
| Original-source retrieval | Implemented baseline | Project-scoped literal and FTS5 lexical search, source IDs, exact UTF-8 paging | Retrieval evaluation, indexing coverage reporting, and larger-archive scaling |
| Context assembly | Partial | Complete current request, bounded recent history, bounded historical excerpts, explicit evidence roles | Exact provider-token admission, full request-envelope accounting, durable invocation snapshots, total episode budgets |
| Semantic retrieval | Not started | Literal and lexical retrieval provide the current baseline | Embedding index, asynchronous jobs, reproducible coverage/frontiers, and comparison against the baseline |
| Service, MCP, and imports | Deferred | Single-process native app owns the store | Multi-client memory service when justified, read-only MCP interface, authenticated imports and adapters |
| Policy and task lifecycle | Not started | Original authorship and capture status are retained | Authenticated lifecycle changes, expiry/reopen rules, separate read/disclosure/processing grants, transitive dependencies |
| Revocation and deletion controls | Not started | No deletion or policy mutation feature is enabled | Durable control epoch, handoff/delivery gate, late-output fencing, safe physical purge |
| External actions | Optional; deferred | No external tool actions are enabled | Durable action journal, explicit unknown outcomes, reconciliation and recovery |
| Retention and recovery | Not started | Local history can reopen after ordinary restart | Backup/restore, retention, purge, recovery drills, and external-blob garbage collection if blobs are introduced |
| Summary tree | Optional; gated | No tree or model-generated archive summaries | Implement only after the raw-retrieval baseline passes its checkpoint; test incremental updates and reproducible frontiers |
| Quality and economics evaluation | Not started | Synthetic fixtures and arithmetic integration smoke tests | Preregistered workload, estimands, clustered confidence intervals, recall/quality/cost/latency comparisons, cache controls and release gates |
| Local release | Development build only | Buildable, ad hoc signed app bundle | Complete release gates, packaging, user documentation and recovery validation |

## Verification

These results were recorded for foundation commit `2574b3b`. They were not rerun for this documentation update.

| Check | Recorded result | What it establishes |
|---|---|---|
| Main automated suite | 183 checks passed | Conversation/profile behavior, GUI fixtures, memory, stream parsing, and loopback HTTP integration |
| Memory suite | 32 checks passed | Includes a separate-process store ownership test; overlaps the main suite |
| Development bundle signature | Strict deep verification passed | Valid ad hoc signature on the built bundle |
| Live mlx-serve CLI and GUI | Two-turn arithmetic succeeded; GUI events persisted | Basic model integration and history forwarding |
| Final visual recheck | Pending | Last UI-control correction passed automated checks but has not been visually rechecked |

These checks do not establish general model competence, long-history recall, latency reliability, or cost improvements. Full details and limitations are in [IMPLEMENTATION.md](IMPLEMENTATION.md).

## Next checkpoint

Finish the read-only baseline before enabling state-changing capabilities. The gaps include crash-safe stream capture, invocation snapshots, provider-token admission, evaluation contracts, and semantic retrieval. Policy mutation, deletion, external actions, and the optional tree require their own contracts and verification gates. The phase mapping below follows the plan's milestones.

| Plan phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Freeze contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External-blob ingest/recovery, quotas beyond the per-payload limit, epoch suppression, deletion fencing and verified backup/restore |
| 2 — Read-only baseline | Partial | Semantic adapter, coverage fallback, CLI/MCP disclosure grants, provider admission, Arm B recall/latency and pilot cost report |
| 3 — Policy/task and optional actions | Not started | Lifecycle and scoped harness tests; action recovery tests if actions are enabled |
| 4 — Optional tree | Gated | Accepted baseline checkpoint before implementation; lineage, frontier and fence verification afterward |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations, frozen baseline/tree comparison and held-out quality/economics gates |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, verified restore and publication of applicable release invariants |
