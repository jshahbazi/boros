# LongMemEval complete-source controls

This separate development diagnostic supplies declared original sources to the counted answering path. It tests whether the model can answer when selected evidence is available. Full declared-source delivery alone does not prove semantic sufficiency or answer correctness. The ordinary recent-only and hybrid recall comparisons retain their original inputs and reports.

## Frozen inputs

The adapter uses the same pinned LongMemEval S dataset, original questions, session dates, question dates and local Qwen configuration as [the seven-case development comparison](LONGMEMEVAL.md). It excludes the abstention case before execution: an empty evidence pack would not establish that the answer is absent from the archive. All six answerable histories remain complete and in their original publication order. Each control has one hybrid attempt, replicate zero, under native input version 6.

The separate selection is derived from positive annotations and original surrounding messages. Scorer answers and annotations remain outside the native request. Every selected source retains its original ID, conversation, role, capture status, date, full UTF-8 bytes and digest. Selected IDs preserve original order. The projection allowlist binds the complete history, question/date and selected IDs; a separate inventory pin binds full source bytes and date provenance. The provider configuration remains independently pinned.

| Case | Declared sources | Original source bytes | Selection |
|---|---:|---:|---|
| `01493427` | 16 | 22,612 | Original antecedent prefix through the following assistant in both positive sessions |
| `00ca467f` | 4 | 5,269 | Original opening exchange in both positive sessions |
| `0e5e2d1a` | 6 | 3,102 | Complete original positive session |
| `06878be2` | 16 | 18,978 | Complete original positive session |
| `001be529` | 12 | 14,830 | Complete original positive session |
| `08f4fc43` | 4 | 5,189 | Original opening exchange in both positive sessions, with original dates |

These packs include surrounding context to retain antecedents and assistant-question relationships. Their adequacy is still a diagnostic question. Each original source fits the existing 4,096-byte page; each pack fits the existing 16-source count limit. Provider token and envelope feasibility require actual counting and admission. No limit is raised to make a control pass.

## Shared preparation

The coordinator forwards an optional internal `evidenceSourceIDs` selection through component preparation. Its default is nil; ordinary Send and prior diagnostic versions keep their retrieval behavior. The declared-source path requires hybrid strategy and the original funded episode. It performs no lexical ranking, query embedding, neighbor expansion or semantic-index construction.

Before reading payloads, preparation validates the bounded unique IDs, rejects the current accepted request, freezes the project source frontier and resolves every original scoped reference. Missing, foreign, empty, oversized or future sources refuse the control. Metadata and payload inspection are prepaid under the same episode. Full scalar-safe reads revalidate original digests; assembly rereads and verifies the resulting evidence under the usual caps. Original capture status remains visible in the general hook; this pinned native diagnostic additionally requires all imported originals to have complete capture status.

Ordinary recent selection still runs. A declared source already retained there contributes to the complete recent/historical source union without duplicate evidence. Undeclared historical evidence is refused. Retained recent distractors may remain, so this is a supplementary-evidence control. Mandatory input, recent/evidence token counting, envelope reduction, full request admission, capture and accounting use the existing production path. Any reduction that removes declared bytes makes complete-pack delivery ineligible.

## Outcome and execution

The native post-terminal `source_control_validation` checks the actual persisted request, admission version 3, count receipt, original source selection and complete declared recent/historical union. It preserves original full history/date/order and complete current-question evidence. Missing preparation leaves the outcome unavailable. Failed validation does not replace the answer or refund charges. This offline inspection is outside episode accounting and is recorded separately; it is not a claim about total runtime cost.

The Python evaluator independently verifies original UTF-8 boundaries, range hashes, scope and interval coverage, plus native projection/configuration and source/body/count links. It publishes a content-free declaration before work, freezes source code and requires a prebuilt app with matching terminal verification. Use absolute fresh output and private hypothesis destinations:

```sh
python3 scripts/evaluate_longmemeval_source_controls.py \
  --source /absolute/path/longmemeval_s_cleaned.json \
  --output /absolute/path/new-source-control-report.json \
  --hypotheses-directory /absolute/path/new-private-hypotheses \
  --binary /absolute/path/verified/Boros.app/Contents/MacOS/Boros \
  --binary-verification /absolute/path/terminal-app-verification.json
```

Private directories use `0700` and files use `0600`. The six-row `source_control.jsonl` exports only `question_id` and `hypothesis`. Incomplete answers export empty hypotheses and remain in the six-attempt denominator. Full source delivery can be verified even when an answer is incomplete; that answer earns no QA credit. Previous reports and exports are retained.

The existing fourteen-attempt local QA tool does not accept these six controls. A separate validated grading contract is required before reporting their QA judgments. Official grading, held-out judge calibration and representative product quality remain unfinished. Current application verification and execution status belong in [STATUS.md](STATUS.md).
