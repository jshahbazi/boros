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

Native answering input versions 4 and 5 carry exact text, role, session identity and original date evidence for each event. Original dataset array pointers and the whole-artifact hash bind source dates. Each original session becomes a separate conversation within its case's project. The query runs in the final session in the supplied array; that session is not necessarily the latest by date. Recent-only sees that conversation's bounded recent messages. Hybrid uses the same recent context and project-scoped historical retrieval across all sessions.

The original natural question stays separate from `question_time`. The accepted query adds the deterministic header `Question Date: <original literal>` before the original question. Timezones remain unspecified. Current counted context framing delivers original session dates; retrieval ranking does not automatically apply a date filter. The subsequent lexical-input amendment derives an explicit UTF-8 range containing only the original natural question for bounded lexical formulation. Version 4 semantic search retains the complete accepted query. Version 5 explicitly opts into the original-question semantic slice with separate projection pins; model input remains complete in both versions. Ordinary Send defaults to the whole prompt; no range is inferred by parsing user prose. Invalid bounds, empty ranges and split UTF-8 scalars are refused. Hashes and offsets of an explicit range join the existing bounded diagnostic trace; exact source delivery and input proofs remain authoritative.

Separate sets of seven exact native projection pins for versions 4 and 5, plus a shared configuration pin, refuse changed text, dates, questions, scopes, settings or oracle fields. Both arms use one replicate, the unchanged default System text, thinking off, ordinary text output, a declared 512-token output bound and the existing 32,768-token context setting. Recent/evidence and episode allowances remain unchanged. Each arm starts from a restored checkpoint; hybrid construction and any incomplete coverage retain their recorded work and failures.

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

Native v4/v5 preparation exports the provider receipt and the exact admission audit persisted by the shared coordinator as separate fields. The scorer checks receipt equality, input-proof linkage and exact decoded context equality before accepting delivery evidence. An unavailable or rejected native report has unknown delivery coverage and contributes no measured delivery denominator; its operational failure remains counted. Validation errors retain a content-free diagnostic hash.

An explicitly requested private hypotheses directory contains one JSONL file per arm, with the official two fields `question_id` and `hypothesis`. Incomplete attempts export an empty hypothesis and retain their failed operational status in the separate report. These files contain source-derived responses and require the same private handling as runtime histories.

Delivery diagnostics validate exact source ranges and distinguish gold-session hits from whole positively labeled turn delivery. They are not official top-k retrieval metrics: Boros may deliver excerpts, while the upstream retrieval baseline indexes user turns and has differing denominator conventions. Abstention cases are excluded from delivery denominators and retained for QA.

QA results remain unscored until the published judge protocol runs. No substring, strict JSON or citation rubric substitutes for semantic QA grading. The official code accepts natural hypotheses and reports overall, category and abstention results. Judge work must be recorded separately; verbose upstream output contains benchmark content. A separate [local-template QA diagnostic](LOCAL-QA.md) is implemented and measured below. Official GPT-4o grading remains unrun. No remote judge execution is enabled by this adapter. LongMemEval-V2, full-benchmark execution, representative workloads and the product decision score remain unfinished.

Primary contracts: [pinned LongMemEval repository](https://github.com/xiaowu0162/LongMemEval/tree/9e0b455f4ef0e2ab8f2e582289761153549043fc), [pinned cleaned dataset](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/tree/98d7416c24c778c2fee6e6f3006e7a073259d48f), [source-time contract](SOURCE-TIME.md) and [shared answering diagnostic](ANSWER-EVALUATION.md).

## Recorded verification

The optimized `.build/boros-longmemeval-final/Boros.app` passed **3,405 application checks** and strict deep signature verification. All 83 native build inputs match their pre-build capture; the full source/test capture contains 139 files. The separate 107 native control assertions overlap the default suite and include 16 new date/checkpoint assertions. All seven native projection/configuration hashes match Foundation serialization, and 3,390 original date pointers match the source artifact. Eight adapter and 29 runner checks are included in that full suite. The initial synthetic checkpoint used an unresolved macOS temporary path; resolving it fixed archive refusal.

The first 14-attempt execution terminalized, but every report was rejected by a scorer/driver contract mismatch: the driver exported a raw provider receipt where the scorer expected the stored admission audit. Its synthetic fixtures repeated that incorrect shape. A preserved one-case replay completed both native arms and reproduced the validation error. The original report's zero delivery aggregates are invalid measurements. The original report and hypotheses remain preserved at `.build/evaluation/longmemeval-natural-v1-20261006.json` and `.build/evaluation/longmemeval-natural-hypotheses-v1-20261006`; diagnosis is recorded in `.build/evaluation/longmemeval-natural-v1-invalidity-20261006.json`. A subsequent repair exposes the persisted audit separately and makes rejected coverage unknown. The repaired `.build/boros-longmemeval-contract-repair/Boros.app` passed **3,406 application checks**, including 30 runner checks and exact stored-audit coordinator assertions, plus strict deep signature verification. All 139 captured source/test files match. Immutable verification: `.build/evaluation/longmemeval-contract-repair-verification-20261006.json`. The unchanged-case repeat terminalized in session `14885`. Recent-only completed 7/7 attempts; hybrid completed 6/7. Its preference response hit the 512-token cap, preserving 1,849 partial bytes and healthy capture/accounting; its private official-format hypothesis is empty. All 14 attempts remain in QA/operational denominators.

| Validated development diagnostic | Recent-only | Hybrid |
|---|---|---|
| Operational completions | 7/7 | 6/7 |
| Gold-session hits across six answerable cases | 0/10 | 1/10 |
| Mean per-case session-hit fraction | 0% | 8.33% |
| Fully delivered positively labeled turns | 0/11 | 0/11 |
| Official QA | Unscored | Unscored |

Only the knowledge-update case has a hybrid gold-session hit. An excerpt hit does not establish complete evidence or answer sufficiency. The abstention case is retained for QA and excluded from these delivery denominators. The subset supplies no representative score.

Report: `.build/evaluation/longmemeval-natural-v2-20261006.json`; private exports: `.build/evaluation/longmemeval-natural-hypotheses-v2-20261006`. Verification in `.build/evaluation/longmemeval-natural-v2-verification-20261006.json` confirms the unchanged source/question/settings/oracle pins, exact immutable binary-proof hash, export hashes/IDs and private permissions. Production query-digest and selected-index reconstruction confirms that five answerable cases use all eight lexical slots for date/header metadata; the remaining answerable case and abstention case use seven metadata terms and one question term. Attribution: `.build/evaluation/longmemeval-query-header-attribution-20261006.json`. The next fix separates natural-question retrieval text from model-facing date metadata, followed by original gold candidate/range inspection and a frozen repeat. Its answer-quality effect remains unmeasured.


## Original-question lexical input amendment

The matching `.build/boros-longmemeval-lexical-range/Boros.app` passed **3,430 application checks** and strict deep signature verification against its 139-file capture. Five new pure query checks verify exact input/default behavior, invalid ranges and Unicode/NUL preservation. The new shared-coordinator fixture uses a metadata-prefixed accepted prompt, selects an archived needle using the original-question range, and verifies full-prompt capture and exact stored admission-audit linkage. The native v4 fixture also checks range equality with the original question.

Immutable verification: `.build/evaluation/longmemeval-lexical-range-verification-20261006.json`. The same-case repeat terminalized in session `93206`, with **14/14 operational completions**. Source/question/settings/oracle pins, semantic query and mandatory model-facing question/date text are unchanged. Selected evidence changes as intended.

| Hybrid development diagnostic | Preceding v2 | Lexical-range v3 |
|---|---|---|
| Operational completions | 6/7 | 7/7 |
| Gold-session hits across six answerable cases | 1/10 | 9/10 |
| Mean per-case session-hit fraction | 8.33% | 83.33% |
| Positive turns in candidate lists | 0/11 | 7/11 |
| Positive turns with any delivered bytes | 0/11 | 7/11 |
| Fully delivered positive turns | 0/11 | 4/11 |
| Cases with all positive turns delivered | 0/6 | 3/6 |
| Official QA | Unscored | Unscored |

Recent-only remained 7/7 operational with zero gold-session hits and whole positive turns. Private exports contain seven complete hypotheses per arm. All seven explicit lexical-input hashes and offsets match the original questions; complete accepted-prompt hashes remain intact.

The remaining range failures are short sources: two multi-session positives of 331 and 271 bytes retain only suffixes, and a temporal positive of 281 bytes loses 17 leading bytes. They fit the existing 4,096-byte per-span bound. The preference session and a second temporal positive remain absent from candidates. Next work promotes bounded short primary hits to complete authoritative ranges and separately diagnoses candidate misses; source byte size alone is not provider token-feasibility proof.

Report: `.build/evaluation/longmemeval-natural-v3-20261006.json`; private exports: `.build/evaluation/longmemeval-natural-hypotheses-v3-20261006`; pin/export/range/candidate verification: `.build/evaluation/longmemeval-natural-v3-verification-20261006.json`. These development diagnostics do not establish semantic QA, the official full score or representative quality.

### Complete short primary sources

Shared selected-Qwen evidence preparation now completes a retrieved fragment when the entire original source fits the existing 4,096-byte page limit. It verifies project/conversation identity, frozen source frontier, role/status/date/digest, original fragment bytes and UTF-8 boundaries before replacement. Excluded sources receive no metadata or payload reads. Duplicate fragments are individually verified; later expansion/assembly retains existing deduplication and candidate limits. The new reads are prepaid under the original episode allowance, including unsuccessful validation. Following-assistant expansion, the 16-candidate limit and provider context budgets remain unchanged.

The optimized `.build/boros-short-primary/Boros.app` passed **3,446 application checks**, including 16 new completion checks, with matching 139-file source/test capture and strict deep signature verification. Synthetic contracts cover Unicode/NUL preservation, original dates and partial status, page/candidate boundaries, corrupted fragments, split scalars, exclusions, foreign/forged/future sources, duplicate reads, nested charging, terminal refusal and budget exhaustion. Immutable proof: `.build/evaluation/short-primary-verification-20261006.json`.

The v4 unchanged-case repeat terminalized successfully in session `83147`: **14/14 operational attempts**. Hybrid delivers **7/11 complete positive turns**, improving from 4/11; mean per-case whole-turn delivery rises from 50% to 75%, and cases with all positive turns delivered rise from 3/6 to 4/6. All three short-prefix failures are recovered. Gold-session hits remain **9/10**; preference evidence and one temporal positive turn remain missing. Recent-only remains at zero gold sessions and whole positive turns. Source/question/settings/oracle pins and semantic/model-facing query inputs remain unchanged. Independent verification reconstructs original byte-range hashes, UTF-8 boundaries and interval unions, and verifies all seven complete private hypotheses per arm and their permissions/hashes. Official QA remains unscored. Report: `.build/evaluation/longmemeval-natural-v4-20261006.json`, SHA-256 `9690b1490fc47f7b04698d5e1567ef53c56820eb2e949d0091abb5294e2c05e3`; private hypotheses: `.build/evaluation/longmemeval-natural-hypotheses-v4-20261006`; verification: `.build/evaluation/longmemeval-natural-v4-verification-20261006.json`. The first launch was refused before declaration because the private destination argument was relative; the corrected launch uses an absolute private path.

### Semantic query-header diagnosis

A separate seven-pair local probe uses the production Apple adapter eligibility guards and installed English sentence embedding on the exact effective prompt and original-question slice. Every date-prefixed effective prompt is rejected as `nonEnglish`; every natural question is supported. The first isolated diagnostic stubs vector normalization; a separate confirmation copies the production normalization verbatim and reproduces all seven pairs. Confirmation: `.build/evaluation/semantic-query-pair-exact-normalization-20261006.json` and `.build/evaluation/semantic-query-pair-exact-verification-20261006.json`. This measures a query-input defect, not answer quality. No provider request was made, and production semantic input remains unchanged for the short-primary completion comparison. Report: `.build/evaluation/semantic-query-pair-20261006.json`; source/helper/input/report hashes: `.build/evaluation/semantic-query-pair-verification-20261006.json`. Next semantic work must use an explicit accepted-question range with separate source/audit proofs and a separately frozen repeat.

### Accepted-question semantic input amendment

The shared coordinator and component preparation now accept an independent optional semantic-query UTF-8 range. It is validated against the complete accepted prompt before retrieval. The exact selected bytes become the semantic manifest query digest, encoder input and prefunded encoder byte charge; the model-facing prompt and its original source/body/count receipts remain complete. Default-nil ranges preserve the full prompt. Recent-only performs no historical or encoder work. Lexical and semantic ranges may differ; neither is inferred from user prose. Hashes, offsets and lengths join the bounded selection trace without query text. Public metadata now retains the existing lexical and new semantic range field names, plus short-primary completion counts/dispositions.

Native input version 5 uses the original-question slice for semantic retrieval. It has seven separately pinned oracle-free projections; versions 1–4 retain their prior contracts, including version 4's full semantic prompt. Source histories, dates, questions, scorer annotations, model configuration and provider budgets are unchanged. Twelve new strategy checks cover actual Unicode/NUL encoder bytes, pre-encoding funding, manifest/trace digest agreement, independent/default ranges, complete mandatory input, recent-only/missing-index behavior and invalid ranges. A new coordinator fixture verifies component forwarding and persisted full-prompt admission evidence. Paired native v4/v5 decode/checkpoint controls preserve original dates and refuse changed inputs and cross-version pins.

The matching `.build/boros-semantic-query-range/Boros.app` passed **3,482 application checks**, including 114 strategy, 649 component-preparation and 24 answering checks, with all 139 captured files matching and strict deep signature verification. Immutable proof: `.build/evaluation/semantic-query-verification-20261006.json`.

The separately declared v5 comparison terminalized with **13/14 operational completions**: recent-only 7/7, hybrid 6/7. All seven original-question semantic hashes/offsets match, and all seven semantic queries are supported. Hybrid still delivers **9/10 gold-session hits and 7/11 complete positive turns**, with all positive turns delivered in 4/6 answerable cases. Mean per-case session coverage rises from 83.33% to 91.67%. The preference gold-session gain is a nonpositive assistant turn; the lost temporal gold-session hit is also nonpositive. The three positive preference turns and one temporal positive remain absent from candidates. Gold-session coverage therefore does not establish improved positive evidence. The preference attempt reaches its original 512-token output cap and remains failed, with 2,304 partial response bytes retained privately and an empty official-format export. No retry replaces it.

Independent verification reconstructs original ranges, UTF-8 boundaries and coverage unions; verifies source/question/configuration/oracle pins and original semantic/accepted-prompt hashes; and checks export IDs, hashes and private permissions. Report: `.build/evaluation/longmemeval-natural-v5-20261006.json`, SHA-256 `04aa2706cfbecff97c1c2abae588b28ae9971cfc9d286c14fe151d991f24901f`; private exports: `.build/evaluation/longmemeval-natural-hypotheses-v5-20261006`; immutable verification: `.build/evaluation/longmemeval-natural-v5-verification-20261006.json`.

### Local QA diagnostic

The separate [local QA tool](LOCAL-QA.md) uses unchanged hash-pinned upstream grading templates with the local Qwen model. Fourteen synthetic paired controls all pass, with zero observed false accepts or false rejects on those controls. Held-out judge calibration remains unrun; the answering and judging model is the same, and runtime/weight identity is unpinned. These are development judgments.

| Local judge result | Short-source v4 | Semantic-question v5 |
|---|---:|---:|
| Recent-only accepted / declared | 1/7 | 1/7 |
| Hybrid accepted / declared | 2/7 | 4/7 |
| Scored judgments / declared attempts | 14/14 | 13/14 |
| Official QA score | Unscored | Unscored |

The failed v5 preference answer remains in the denominator and receives no judge call or credit. Across controls and both reports, 41 judge calls report 10,625 prompt tokens and 41 completion tokens, recorded separately from Boros episode charges. Private request/response hashes and permissions match the pre-execution declarations. Results: `.build/evaluation/local-qa-v4-v1-20261006/report.json` and `.build/evaluation/local-qa-v5-v1-20261006/report.json`; controls: `.build/evaluation/local-qa-controls-v1-20261006/report.json`; immutable results proof: `.build/evaluation/local-qa-results-verification-20261006.json`. The current default suite passes **3,502 checks**, including 20 portable local-QA contracts, against 141 captured source/test files; native sources and the verified app binary are unchanged. Proof: `.build/evaluation/local-qa-verification-20261006.json`. Official GPT-4o grading, the full benchmark and representative product quality remain unfinished.
