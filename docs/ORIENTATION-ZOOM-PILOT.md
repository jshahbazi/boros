# Early orientation and inspection experiment

The user authorized moving this experiment ahead of the remaining retrieval repairs on October 6, 2026. It tests a compact overview of the full history followed by model-directed search or zoom into original exchanges. It is a standalone diagnostic. The native application and its local answering defaults are unchanged.

**Audit correction and execution hold:** the [independent correctness audit](reviews/ORIENTATION-ZOOM-AUDIT-20261006.md) found that model-visible event and session IDs expose `_abs` metadata. All fifteen answers for the five abstention histories received this answerability cue. The earlier 11/13 headline is not clean accuracy evidence. The eight matched answerable cases remain 6/8 in every arm, with the same annotated-turn counts. Summary coverage is structurally verified; semantic fidelity is unvalidated. The user prohibited any experiment rerun or continuation until explicit authorization. Restored credits alone do not authorize execution, and v1 continuation retains the leakage.

## Frozen comparison

Three arms use the same GPT-6.1 Sol final reader, original question and question date, source rendering, answer instructions and output limit:

1. **Lexical exchange:** system-SQLite FTS5/BM25 over original messages, selecting complete conversational exchanges in one pass.
2. **Inspection:** the same initial selection followed by at most two model-directed search or zoom actions.
3. **Orientation and inspection:** the same inspection loop with a question-blind, source-linked summary of every original session.

The first arm is a standalone lexical complete-exchange control. It does not execute native Apple hybrid retrieval or selected-Qwen admission. The second arm separates the value of another inspection pass from the contribution of the overview. These are development package comparisons; they do not isolate every selector implementation difference from production Boros.

The overview is built once per history from allowlisted original records. Every original session appears exactly once; summaries have at most 240 Unicode characters and one or two valid original source links. Summary generation excludes explicit question, reference-answer, task-category and positive-annotation fields; the later audit found an implicit answerability cue in source IDs. Search covers the full original index; zoom reads an identified session or exchange. Newly requested evidence can displace initial units within the same allocation. Byte-fit evictions are explicit; later token-fit evictions are reconstructible from count traces. Whole exchanges preserve exact original bytes, roles and source-time evidence. Summaries and planner prose never become final-answer evidence.

The fresh cohort contains 30 histories: five abstentions, four cases in each of six answerable categories, and one additional multi-session case. The initial fixed selector could not fill six abstention slots under its exclusion and disjointness rules; the replacement allocation selects five abstentions first. Selection uses the fixed `boros-orientation-zoom-development-v1` hash domain, excludes all 21 earlier cases and their complete session IDs/payloads and question bytes, and never uses answers or positive labels. The case inventory and selection proof are frozen before outputs.

## Budgets and judging

Recent originals have an 8,000-token cap; historical evidence has a 12,000-token cap. The overview has an 8,000-token cap. Every foreground request has at most 24,576 actually counted input tokens plus an 8,192-token API output reserve, within 32,768 total. Planner context fitting removes complete original units while retaining the whole overview and complete question. Final visible answers have at most 1,024 tokens. Offline overview creation has a separate 262,000-input-token cap and a 16,384-token output reserve; its cost and latency are reported separately.

The full run declares 90 answering attempts, at most 510 generation attempts and 4,096 HTTP attempts. Aggregate input/output reservations enforce 20 million input and one million output tokens; requests with unknown usage retain their full reservation. Requests are never retried automatically. Failures and unresolved judgments remain in the declared denominators.

Source-only sufficiency is assessed once for each exact question/evidence pack before its answer is generated. The candidate answer is absent from that prompt. Every complete answer receives the unchanged hash-pinned upstream LongMemEval category QA prompt, regardless of sufficiency or annotated recall. A separate support assessment receives original evidence and the candidate without the reference answer. These Sol-generated labels remain uncalibrated; using the upstream prompt does not establish official benchmark scores or independent human adjudication.

Report paired QA wins/losses, supported-answer acceptance, full annotated-turn recovery, unknowns/failures, model calls, observed usage and stage latency. Retain the existing targets of at most 500 ms added memory p95 and 10% added total-episode p95. The first pilot can diagnose a useful direction; representative accuracy and native performance require subsequent confirmation.

## Execution and evidence

The runner is [evaluate_orientation_zoom.py](../scripts/evaluate_orientation_zoom.py). Pure memory/tool and separated judging primitives have synthetic contracts. All source-bearing inputs, model traffic, answers and receipts are private under ignored `.build/evaluation` directories, with no-clobber files and captured source dependencies. Public documentation contains only code/design prose, hashes and aggregate results.

The pinned source is LongMemEval S revision `98d7416c24c778c2fee6e6f3006e7a073259d48f`, SHA-256 `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`. The upstream QA template SHA-256 is `ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251`. A declaration binds exact input/scorer/configuration/dependency hashes before any generation.

## Terminal partial result

The declared attempt is terminal and independently authenticated. All 90 rows remain. The provider returned 67 generation HTTP 429 failures; a separate small access probe's private error body identifies a credit/quota limit. The attempt completed 43 answers and built 21 structurally valid whole-history views. Four completed baseline answers have unresolved QA; only 13 histories have completed answers and valid QA labels in all three arms. That matched subset contains five abstentions, four knowledge-update questions and four multi-session questions. The five abstentions received leaked answerability metadata. Assistant recall, user recall, preference and temporal reasoning remain entirely unjudged. The 30-case experiment is incomplete and on hold by explicit user instruction. Preserve its captures; correcting identifier leakage requires a new experiment identity and authorization.

| Historical 13-case observations, including contaminated abstentions | Lexical exchange | Inspection | Orientation and inspection |
|---|---:|---:|---:|
| QA accepted | 11/13 | 11/13 | 11/13 |
| Answerable QA accepted | 6/8 | 6/8 | 6/8 |
| Full annotated turns delivered | 17/23 | 20/23 | 18/23 |
| QA plus claim/citation support accepted | 10/13 | 10/13 | 11/13 |
| Model-selected search/zoom actions | 0 | 15 | 13 |
| Matched memory p95, seconds | 8.961 | 15.283 | 13.183 |
| Matched episode p95 excluding diagnostic judges, seconds | 11.681 | 19.476 | 17.236 |

Every matched case receives the same QA verdict across arms. Inspection improves annotated evidence coverage in this subset, without improving answers. Orientation adds no observed QA benefit and recovers fewer annotated turns than inspection alone. Its one additional support acceptance occurs with an identical final evidence pack and zero tool actions in all arms, so that difference cannot be credited to orientation. These model judgments remain uncalibrated.

The standalone remote prototype exceeds the existing added-memory and episode-latency targets in this subset. Its timings include remote token counting and three concurrent case workers; they are not native GUI latency measurements. Orientation creation p95 is separately 66.531 seconds across the matched cases. No completed final answer exhausts the visible output cap; the maximum is 211 non-reasoning tokens. The incomplete comparison does not justify enabling a production summary tree. Finish the remaining categories before selecting an architectural direction.

The run records 1,066 HTTP attempts and 279 generation attempts, including failures; one additional access probe is recorded separately. Observed generation receipts total 6,804,278 input tokens, 82,826 output tokens and 422,641 cached input tokens. The $14.436816 estimate applies standard input/output rates without a cache discount, using [official Sol pricing](https://developers.openai.com/api/docs/models/gpt-6.1-sol). It is an observed-receipt estimate, not an invoice or an upper bound on unknown usage. The 67 rejected generation requests retain conservative unknown reservations.

Evidence lives in `.build/evaluation/orientation-zoom-v1-20261006`: declaration SHA-256 `081eb8c967c0ee0fc1bdb61c9fe74471c4921323ae456836226e8cbf520ebdec`, report SHA-256 `81cc1582829969ee22cc01c53d4e63d594b10bc03dac14173079cd334122041c`, inputs SHA-256 `9eed7dee5b76764b473604375f0dfb819cb06630447c2d9de5d2aa1e98cdfbc5`, scorer SHA-256 `37265a857743a8a19982596019f6c28f8f9c292c9e4bf0f0e9b0fd9ab474163c`. Independent verification is `.build/evaluation/orientation-zoom-verification-20261006/verification.json`, SHA-256 `b0eac25474ec5182245c381318ad49e3327460fd3819056cb612ff6f95f03d48`; matched comparison SHA-256 `0e507fbaaa89b260ce18b2bdf126dfa8cf8f9a82e88e696872b28e6f34b9c8c3`.

Sixty-one synthetic contracts now pass, including sixteen continuation contracts. The live run has eleven captured execution dependencies. Its capture precedes a post-run reporting guard for missing setup timings; that guard does not change requests or selection. Committed-dependency compatibility checks reproduce the exact same inputs/scorer without provider calls. No private original text, dates, model output or credentials enter Git.

## Completing the frozen comparison

[continue_orientation_zoom.py](../scripts/continue_orientation_zoom.py) authenticates the original terminal report, declaration, eleven captured source modules and every recorded request/response pair. It executes those captured modules, preserving the original experiment configuration. Generation reuse requires the same stage name, request kind and exact canonical request hash; identical request bodies from different stages retain their distinct responses. Source-only sufficiency is the sole generation exception: a valid label, including unknown, is reused for an identical canonical question/evidence assessment across arms. Token counts also reuse an identical canonical body. The original directory is immutable, and continuation artifacts require a fresh private directory.

Preparation is offline by default:

```sh
python3 scripts/continue_orientation_zoom.py \
  --output "$PWD/.build/evaluation/orientation-zoom-v1-continuation-20261006" \
  --protocol "$PWD/.build/longmemeval-protocol-20261006/src/evaluation/evaluate_qa.py"
```

Execution requires renewed explicit user authorization. V1 continuation retains leaked identifiers and should not be used for clean confirmation. Its mechanics require a new output directory and `--execute --fill-unreceived`; these flags do not supersede the user's hold. The pilot was written for the retired OpenAI route; any future remote execution uses [Vertex AI in the `llm-train` project](DESIGN-REPAIR-PLAN.md#remote-evaluation-provider) and needs a Vertex adapter first. Those explicit flags are recorded before dispatch. Previously unreceived stages can receive one fresh dispatch; completed captures are retained without paid regeneration. One worker reserves at most 300,000 tokens per rolling minute. The first new HTTP 429 fences every missing request while allowing authenticated reuse. There are no automatic retries.

The continuation separates original observed usage, retained captures, new receipts and unknown reservations. Replayed timings do not establish fresh product latency; the continuation suppresses latency p95 rather than pooling cached and new stages. Its source, protocol, controller and authorization manifest are checked before dispatch, including after rate waits. The offline continuation preflight passed against the original run without provider calls. All remaining model work is on hold pending explicit user authorization of a corrected design and spending limit.
