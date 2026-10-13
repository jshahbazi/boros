# BEAM long-history cohort and the per-category baseline

Record date: October 13, 2026. The 20-question BEAM comparison ([EXCHANGE-PACKED-ANSWERS.md](EXCHANGE-PACKED-ANSWERS.md), [READER-CHOICE.md](READER-CHOICE.md)) has two questions per category, which cannot measure a category. This record builds a cohort of 100 questions from five BEAM conversations at both benchmark scales and measures today's ordinary Send on it per category. The multi-source path measured against this baseline is in [MULTI-SOURCE-ANSWERS.md](MULTI-SOURCE-ANSWERS.md). Each section states whether it reports implemented behavior, measured results or inferences.

## Cohort (implemented, `scripts/beam_cohort.py build`)

The inputs are the public BEAM benchmark parquet files that the OptChat repository holds read-only (`beam-100K.parquet`: 20 conversations; `beam-500K.parquet`: 35 conversations; each conversation has 20 probe questions, two per category, CC BY-SA 4.0). Nothing in that repository was modified.

| Scale | Conversation | Sessions | Messages | Text (UTF-8 bytes) | Questions | Author-resolved gold turns |
|---|---|---:|---:|---:|---:|---:|
| 100K | 1 | 3 | 188 | 523,108 | 20 | 54 |
| 100K | 2 | 3 | 200 | 493,172 | 20 | 55 |
| 500K | 1 | 10 | 796 | 1,862,256 | 20 | 84 |
| 500K | 2 | 10 | 880 | 2,038,098 | 20 | 87 |
| 500K | 3 | 10 | 772 | 1,787,384 | 20 | 72 |
| All | 5 | 36 | 2,836 | 6,704,018 | 100 | 352 |

Ten questions per category: abstention, contradiction resolution, event ordering, information extraction, instruction following, knowledge update, multi-session reasoning, preference following, summarization, temporal reasoning. 500K conversation 1 is the conversation of the 20-question comparison; its question identities are reused from OptChat's normalized case, so the 20 earlier labels are the same 20 labels here (`reused`: 20 of 20 questions equal in text, reference answer and resolved gold sequences).

Normalization follows OptChat's `normalized-case-1` shape (checked field by field against the 500K-1 case: question text, reference field per category, compact-JSON rubric, gold resolution from `source_chat_ids`, native question object) with two deliberate differences:

- **Dates.** Each BEAM session has one date anchor. OptChat prefixed the session's first message text with it. Here every message of a session carries the session date as its `source_time` at day precision, the schema-10 original source-time contract, so the V4 headers show it for every quoted source. BEAM's `Month-DD-YYYY` literal is converted to ISO `YYYY-MM-DD` because the source-time schema accepts only explicit calendar literals; the locator points at the session's anchor. The other 786 of 796 message texts of 500K-1 are byte-identical to OptChat's.
- **System text.** The comparison's base instruction asked for original source identifiers, which the V4 framing forbids (R6 of the [context diagnostic response](reviews/CONTEXT-DIAGNOSTIC-RESPONSE-20261012.md)). The cohort's instruction asks for host citation labels instead; everything else in it is the same in substance.

No question date is given, as in the comparison. Reference answers exist for seven categories; summarization, instruction following and preference following have none, and the grader judges them from the rubric and the native question object. The cohort manifest (`cohort.json`) carries labels, categories, counts and hashes only; the cases are private.

## Capture (implemented, `scripts/beam_cohort.py capture`)

For every question the delivery harness at this checkout runs the ordinary Send configuration (`exchange_packed`, framing `context-source-snapshot-v4-advice`, the defaults since October 12) in a disposable store holding the whole conversation, with the question as the next turn of that conversation, and writes the exact answer request body. No answer is generated. The rows record delivery (recent source IDs, evidence byte ranges), prompt tokens, gold delivery (`whole` when every author-resolved gold message is delivered whole, `partial`, `none`, or `no_gold_turns`) and the retrieval audit's mode and counts.

MEASURED_CAPTURE_PLACEHOLDER

## Baseline (measured)

MEASURED_BASELINE_PLACEHOLDER

## Privacy and artifacts

Cases, request bodies, answers and grades are in `.build/beam-cohort-20261013/` of worktree `agent-ab324e6f37c8d1b84` (0700 directories, 0600 files). This record contains no question, answer, reference or conversation text.

## Reproduce

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_cohort.py build --output .build/beam-cohort-20261013
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_cohort.py capture --output .build/beam-cohort-20261013
```

The generation, grading and scoring commands are in [MULTI-SOURCE-ANSWERS.md](MULTI-SOURCE-ANSWERS.md). Tests: `scripts/test_beam_cohort.py` (6 synthetic contracts), run by `check.py`.
