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

Capture result (measured, October 13; harness built from this checkout's 105 Swift sources): 100 of 100 requests prepared under `exchange_packed` and `context-source-snapshot-v4-advice`, no failure, no answer runner started. Median prompt 16,239 Qwen-tokenizer tokens (16,969 Gemini tokens), about 2,000 more than the October 12 capture because every quoted source now carries a source-time header. Gold delivery of the 352 author-resolved gold turns: 127 whole. By question: 45 whole, 34 partial, 10 none, 11 with no resolvable gold.

| Category | Gold turns | Delivered whole | Questions whole / partial / none |
|---|---:|---:|---|
| Abstention | 0 | 0 | no gold (10) |
| Contradiction resolution | 23 | 18 | 6 / 3 / 1 |
| Event ordering | 74 | 13 | 0 / 7 / 3 |
| Information extraction | 14 | 9 | 6 / 2 / 2 |
| Instruction following | 15 | 12 | 7 / 3 / 0 |
| Knowledge update | 17 | 14 | 6 / 3 / 0 |
| Multi-session reasoning | 40 | 20 | 2 / 7 / 1 |
| Preference following | 11 | 11 | 10 / 0 / 0 |
| Summarization | 139 | 14 | 0 / 8 / 2 |
| Temporal reasoning | 19 | 16 | 8 / 1 / 1 |

The three multi-source categories are the three with the lowest delivery: the 12,000-token evidence component holds about ten whole exchanges, and event ordering and summarization need 7 and 14 gold turns per question on average, spread over the history.

## Baseline (measured)

Today's default, measured on October 13 as the `ordinary_send` arm of [MULTI-SOURCE-ANSWERS.md](MULTI-SOURCE-ANSWERS.md): the captured requests answered by Vertex Gemini 3.8 Flash (thinking "low", 2,048 output tokens plus a 2,048-token thinking allowance, no sampling field), three replicates, graded by the same model with OptChat's `beam-native-grader-1` request (three replicates, majority on `correct`). All 300 answers and 1,734 grade requests completed; no verdict was unknown and no grade replicate reported low confidence.

- **Calibration.** 100 of 100 fabricated negatives rejected; 78 of 80 authored positives accepted (there is now a positive for every summarization question, its ideal summary). The two rejected positives are both temporal-reasoning references, one of them the reference OptChat's own grader also rejected on October 12 (`fb212bbc`). OptChat's rule requires every positive, so as on October 12 these are grades under one calibrated-but-not-accepted grader, read as paired comparisons; the baseline below is reported with that caveat.
- **Overall.** Mean per-question accept rate 49.7 percent (95 percent bootstrap interval over questions 40.0 to 59.0); 50, 50 and 49 correct of 100 per replicate; 92 of 100 questions received the same verdict on all three replicates; 39 of 300 answers declined. Median answer 649 characters, 172 output tokens, 3.6 s; $0.028 per answer at the standard rate.

| Category | n | Accept rate | 95 percent interval | Questions at 0 of 3 |
|---|---:|---:|---|---:|
| Abstention | 10 | 66.7 | 36.7 to 90.0 | 3 |
| Contradiction resolution | 10 | 0.0 | 0.0 to 0.0 | 10 |
| Event ordering | 10 | 0.0 | 0.0 to 0.0 | 10 |
| Information extraction | 10 | 76.7 | 50.0 to 100.0 | 2 |
| Instruction following | 10 | 66.7 | 40.0 to 93.3 | 2 |
| Knowledge update | 10 | 93.3 | 83.3 to 100.0 | 0 |
| Multi-session reasoning | 10 | 30.0 | 10.0 to 60.0 | 7 |
| Preference following | 10 | 80.0 | 50.0 to 100.0 | 2 |
| Summarization | 10 | 6.7 | 0.0 to 20.0 | 9 |
| Temporal reasoning | 10 | 76.7 | 50.0 to 100.0 | 2 |

By scale: 58.3 percent on the 40 questions of the 100K conversations and 43.9 on the 60 of the 500K conversations. On the 20 reused questions the rate is 45.0 percent, against 46.7 for the same questions under `exchange_packed` with framing V4 on October 12 (one question worse, none better): the source-time headers and the label-aligned instruction changed nothing detectable there, and the earlier 9 to 10 of 20 was within replicate noise of today's 9 of 20.

What the baseline establishes (inferred): the failure the user experiences is concentrated and categorical. Single-fact, preference, instruction and temporal questions are answered two thirds to nine tenths of the time; every contradiction and event-ordering question is wrong on every replicate, summarization nearly so, and multi-session reasoning fails seven of ten. Those four categories hold 40 of the 52 questions never answered correctly. The 20-question comparison saw the same four at zero, so with ten questions per category this is no longer a two-question artifact.

## Privacy and artifacts

Cases, request bodies, answers and grades are in `.build/beam-cohort-20261013/` of worktree `agent-ab324e6f37c8d1b84` (0700 directories, 0600 files). This record contains no question, answer, reference or conversation text.

## Reproduce

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_cohort.py build --output .build/beam-cohort-20261013
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_cohort.py capture --output .build/beam-cohort-20261013
```

The generation, grading and scoring commands are in [MULTI-SOURCE-ANSWERS.md](MULTI-SOURCE-ANSWERS.md). Tests: `scripts/test_beam_cohort.py` (6 synthetic contracts), run by `check.py`.
