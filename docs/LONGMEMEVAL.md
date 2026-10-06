# LongMemEval development adapter

This adapter supplies natural questions, knowledge updates and temporal cases to Boros's shared selected-Qwen answering path. It is a separately frozen development subset. It does not establish an official benchmark score, independent real-user histories or the product quality gate.

## Source and subset

Use the complete `longmemeval_s_cleaned.json` at cleaned dataset revision `98d7416c24c778c2fee6e6f3006e7a073259d48f`. The adapter verifies **277,383,467 bytes** and SHA-256 `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442` before parsing. Dataset payloads remain outside Git.

The seven case IDs were selected before any answering results: lexicographically first non-abstention ID in each of the six question types, followed by the first abstention ID. Their declared order is:

| ID | Category |
|---|---|
| `01493427` | Knowledge update |
| `00ca467f` | Multi-session |
| `0e5e2d1a` | Single-session assistant |
| `06878be2` | Single-session preference |
| `001be529` | Single-session user |
| `08f4fc43` | Temporal reasoning |
| `031748ae_abs` | Knowledge update with abstention grading |

All selected session messages are preserved: 338 sessions, 3,383 events and 3,453,146 UTF-8 source bytes. The supplied array order is retained. Repeated original session IDs remain separate source occurrences; one selected history contains a repeated session ID. Inspection of the complete release found only 289/500 histories chronologically ordered and 76 with a session date later than the question. Sorting or a question-date cutoff would change the supplied input.

## Answering boundary

Native answering input version 4 carries exact text, role, session identity and original date evidence for each event. Original dataset array pointers and the whole-artifact hash bind source dates. Each original session becomes a separate conversation within its case's project. The query runs in the final session in the supplied array; that session is not necessarily the latest by date. Recent-only sees that conversation's bounded recent messages. Hybrid uses the same recent context and project-scoped historical retrieval across all sessions.

The original natural question stays separate from `question_time`. The accepted query adds the deterministic header `Question Date: <original literal>` before the original question. Timezones remain unspecified. Current counted context framing delivers original session dates; retrieval ranking does not automatically apply a date filter.

Seven exact native projection pins and a separate configuration pin refuse changed text, dates, questions, scopes, settings or oracle fields. Both arms use one replicate, the unchanged default System text, thinking off, ordinary text output, a declared 512-token output bound and the existing 32,768-token context setting. Recent/evidence and episode allowances remain unchanged. Each arm starts from a restored checkpoint; hybrid construction and any incomplete coverage retain their recorded work and failures.

Gold answers, question types, `answer_session_ids` and optional per-turn `has_answer` remain in the scorer. Integer gold answers and assistant evidence labels are preserved. Session gold is independent of turn labels; some gold sessions have no positively labeled turn.

## Run locally

The selected Qwen server must be available at the pinned loopback endpoint. Use fresh report and hypothesis paths:

```sh
python3 scripts/evaluate_longmemeval.py \
  --source /absolute/path/longmemeval_s_cleaned.json \
  --output /absolute/path/new-report.json \
  --hypotheses-directory /absolute/path/new-private-hypotheses
```

The default command freezes its source inventory before compiling an isolated native driver. A prebuilt driver requires both `--binary` and `--binary-verification`; the verification record must establish a terminal successful build, exact binary hash and matching complete native source inventory. Existing report/export destinations and changed implementation inputs are refused. A content-free declaration is saved before compilation or provider work.

## Reporting and grading

The ordinary report contains fixed metadata, counts and hashes. It contains no questions, answers, source text, original date literals or System text. Every declared attempt remains in its operational denominator. Missing, interrupted and failed attempts remain explicit.

An explicitly requested private hypotheses directory contains one JSONL file per arm, with the official two fields `question_id` and `hypothesis`. Incomplete attempts export an empty hypothesis and retain their failed operational status in the separate report. These files contain source-derived responses and require the same private handling as runtime histories.

Delivery diagnostics validate exact source ranges and distinguish gold-session hits from whole positively labeled turn delivery. They are not official top-k retrieval metrics: Boros may deliver excerpts, while the upstream retrieval baseline indexes user turns and has differing denominator conventions. Abstention cases are excluded from delivery denominators and retained for QA.

QA results remain unscored until the published judge protocol runs. No substring, strict JSON or citation rubric substitutes for semantic QA grading. The official code accepts natural hypotheses and reports overall, category and abstention results. Judge work must be recorded separately; verbose upstream output contains benchmark content. No remote judge execution is enabled by this adapter. LongMemEval-V2, full-benchmark execution, representative workloads and the product decision score remain unfinished.

Primary contracts: [pinned LongMemEval repository](https://github.com/xiaowu0162/LongMemEval/tree/9e0b455f4ef0e2ab8f2e582289761153549043fc), [pinned cleaned dataset](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/tree/98d7416c24c778c2fee6e6f3006e7a073259d48f), [source-time contract](SOURCE-TIME.md) and [shared answering diagnostic](ANSWER-EVALUATION.md).

## Recorded verification

The optimized `.build/boros-longmemeval-final/Boros.app` passed **3,405 application checks** and strict deep signature verification. All 83 native build inputs match their pre-build capture; the full source/test capture contains 139 files. The separate 107 native control assertions overlap the default suite and include 16 new date/checkpoint assertions. All seven native projection/configuration hashes match Foundation serialization, and 3,390 original date pointers match the source artifact. Eight adapter and 29 runner checks are included in the full suite. The initial synthetic checkpoint used an unresolved macOS temporary path; resolving it fixed archive refusal. The first 14-attempt paired real-model execution is active; no result or QA score is established yet.
