# JevK5 judging of saved answers

On October 6, 2026, the user authorized using their `jevk5-judge` MCP server to judge existing results. This authorizes the saved-answer QA pass described here. The retrieval experiment, its continuation and new answer generation remain on hold.

[jevk5_saved_qa.py](../scripts/jevk5_saved_qa.py) connects to the supplied local `mcpme connect --slot` command. The service reports `JevK5-4B-v0.3-Q8_0`, model SHA-256 `aea433883bc7ed399f2fbd539e53d2eac7caf71a946fe6650995a413979d4a30`, profile `m5-benchmark-v1` and an 8,192-token context. It exposes `jevk5_decide` and `jevk5_status`. Decisions return a selected option, probabilities, input-token count and model/cache metadata, without an explanation.

## Grading contract

The adapter authenticates the original terminal report, declaration, eleven captured source modules, all forty-three completed answer byte sequences and their response receipts. It renders the unchanged hash-pinned upstream category QA prompt, then supplies it as `evaluation_prompt` to JevK5's structured choice interface with options `yes` and `no`. It sends no arm names, prior Sol labels or report case IDs as additional grading fields. Existing candidate citations retain their original IDs; the answer-generation contamination remains recorded.

Six public controls cover a correct answer, an incorrect answer, missing required information, an obsolete knowledge-update answer, valid abstention and an unsupported guess on an unanswerable question. All six must pass before saved answers are graded. The pass allows at most forty-nine sequential decisions, with no retries; a transport, protocol or model-validation failure stops further calls. Private no-clobber captures and a pre-dispatch declaration bind the requests, controller, protocol, executable and model identity. The previous ninety attempt rows remain, including forty-seven unavailable answers.

This measures reference-based QA acceptance. It does not assess source-pack sufficiency, claim support, citation fidelity or summary accuracy. JevK5 probabilities have no task-specific calibrated acceptance threshold. Synthetic controls establish basic behavior, not representative accuracy or human adjudication. The structured wrapper and local model differ from the official benchmark judge.

## Observed result

All six controls passed. JevK5 graded all forty-three saved answers with no failed judgment or unresolved available answer. It agreed with Sol on **36/39** previously judged answers. The three disagreements concern one contaminated abstention history across the three arms: Sol accepted each answer and JevK5 rejected each. Four previously unresolved Sol QA rows now have a JevK5 label; these are extra baseline answers and cannot be pooled into a matched arm comparison.

| Same eight matched answerable histories | Lexical exchange | Inspection | Orientation and inspection |
|---|---:|---:|---:|
| JevK5 QA accepted | 6/8 | 6/8 | 6/8 |
| Sol QA accepted | 6/8 | 6/8 | 6/8 |
| Full annotated turns delivered, unchanged | 17/23 | 20/23 | 18/23 |

Across the historical thirteen-case matched subset including contaminated abstentions, JevK5 accepts 10/13 in each arm versus Sol's 11/13. Neither result repairs the leaked answerability cue. The existing answerable observations still show no orientation QA gain, with four question categories untested.

The forty-nine decisions report 16,996 input tokens, a maximum of 590 per decision and three exact-consecutive cache hits. Median service latency is 117.310 ms; the fifty-three MCP operations take 6.936 seconds in aggregate. These are local judging timings, not retrieval or answer-generation latency. A separate public arithmetic smoke decision preceded the frozen pass and is not included in its forty-nine-call totals. No OpenAI or other remote-provider call occurred.

## Evidence and implementation boundary

The private result is `.build/evaluation/jevk5-saved-qa-v1-20261006/report.json`, SHA-256 `108a9495dbf8809cf0904567096236a0a3a0ddda1f06f2c64d7f44d37a4769d5`; declaration SHA-256 `e7f7a34703a12c5e7670f0d39a1db8302891705187e8658b697f89857b19cdb4`. An independent seventy-three-check receipt audit reproduces requests, candidate bindings, decisions, probabilities and aggregate results: `.build/evaluation/jevk5-saved-qa-verification-20261006/verification.json`, SHA-256 `61ac4da5643b8f12b14330ba46b853c3e742a2bd3f935c897e8b25b3a3528629`. Request bodies, candidate text and model receipts remain ignored and private. The original report SHA-256 remains `81cc1582829969ee22cc01c53d4e63d594b10bc03dac14173079cd334122041c`.

Nineteen synthetic adapter contracts pass, including private publication, receipt validation, probability/model checks, failure fencing and fake stdio transport. Independent review precedes the live pass. This is a standalone saved-answer grader; native Boros defaults and the production model route remain unchanged. Do not rerun or resume the retrieval experiment without explicit user authorization.
