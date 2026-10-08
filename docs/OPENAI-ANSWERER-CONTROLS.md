# OpenAI and Qwen answerer controls

The user authorized an OpenAI API diagnostic on October 6, 2026, requesting `gpt-6.1-sol`. A metadata request verified access to that exact model. The [OpenAI Docs skill](/Users/johnshahbazian/.codex/skills/.system/openai-docs/SKILL.md) was used to verify the API/model contract. This diagnostic follows the [architecture reassessment](reviews/ARCHITECTURE-REASSESSMENT-20261006.md); it does not enable remote processing in the Boros application.

## Question and inputs

Can the selected local answerer and GPT-6.1 Sol answer five known failing development cases when given curated original evidence? This bypasses retrieval. It does not rerun the earlier native contexts, whose exact request bodies were not found in the inspected retained artifacts.

The cases are the three diagnosed missing-target failures (`51c32626`, `1b9b7252`, `4baee567`) and the two newly rejected experimental answers with all annotated positives delivered (`54026fce`, `gpt4_70e84552`). Selection uses known diagnostic failures and scorer annotations; it cannot establish representative accuracy or a blind production retrieval improvement.

The five candidate packs contain 66 complete original messages and 68,197 UTF-8 bytes. Each has at most sixteen sources; every source is at most 4,096 bytes. Independent original-source reconstruction verifies all seven annotated positive turns, roles, order, original date metadata, source hashes and question/reference pins. The selected sources form original-order complete sessions or contiguous session prefixes. Semantic sufficiency remains unverified before generation.

Answering inputs contain only questions, original dates and selected original sources. Scorer references and annotations are stored separately and never enter answerer requests. Private files use `0600`, within `0700` directories.

## Execution contract

`scripts/evaluate_answerer_controls.py` uses the standard library and four fixed endpoints: OpenAI Responses/counting, and loopback Qwen chat/tokenization. TLS uses default certificate verification; redirects and environment proxies are refused. HTTP error messages are discarded. Response bodies are bounded; failures preserve dispatch state, any observed usage and explicit unknown usage.

Each provider processes the five cases in the same fixed order, with at most two independent provider workers. The logical comparison has ten declared answer attempts and twenty declared source-aware judge attempts. A fresh complete execution permits at most forty count requests and seventy HTTP attempts. There are no automatic retries or changes of model, reasoning, prompt or caps. Before generation, the runner freezes all answer requests, input/scorer hashes, its own source hash and the common message-content hashes. It checks those pins around provider calls and binds each judge request to the saved answer bytes/hash.

The terminal v1 attempt used an incorrect Qwen count route, `/v1/tokenize`. All ten Qwen count requests returned HTTP 404; no Qwen generation ran. Five Sol answers and five Sol self-judgments completed. The failed attempt, its exact runner and all denominators remain preserved. Independent review authenticated those ten successful captures and fifteen Sol count receipts.

The explicit v2 amendment corrects the Qwen route to `/tokenize` and reuses only the pinned v1 Sol captures. Its parent report, original input and prompt pins, copied operation hashes, answer bytes, usage and reconstructed judge requests must all agree. It declares five reused answers, five reused judgments, twenty new generation attempts, at most twenty-five new count requests and forty-five new HTTP attempts. Reuse adds no second Sol answer or self-judgment call. Parent operations remain a separate receipt inventory so costs are counted once.

Both answerers receive the same ordered system, evidence and question message contents. The fixed instructions request concise answers, original-source citations and abstention when evidence is insufficient. There is no recent-context distractor allocation or memory-tool loop in this clean-pack control.

| Setting | Qwen | GPT-6.1 Sol |
|---|---|---|
| Model | `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` | `gpt-6.1-sol` |
| Thinking/reasoning | Thinking off | Low reasoning |
| Sampling | Temperature 0, fixed seed | No temperature or seed override |
| Total output allowance | 1,024 tokens | 8,192 tokens, including reasoning |
| Non-reasoning output check | At most 1,024 provider-reported tokens | At most 1,024 provider-reported tokens after subtracting reasoning |
| Evidence allowance | 12,000 tokens in the rendered evidence block | 12,000 tokens in the isolated evidence-message count |
| Full prompt check | Input plus output reserve plus 256 safety tokens ≤32,768 | Input plus output reserve plus 256 safety tokens ≤32,768 |

Sol requires a supported reasoning effort; `none` is unavailable. Its total output limit includes reasoning. Provider output usage minus reported reasoning is a conservative upper bound on visible text, because formatting tokens can remain. It must not be described as exact visible-token usage. Output beyond that bound or a truncated/refused response remains a failed control, retaining its receipt. See [the official model contract](https://developers.openai.com/api/docs/models/gpt-6.1-sol) and [token accounting](https://developers.openai.com/api/docs/guides/token-counting).

Qwen counting uses the public nonthinking renderer subset and `/tokenize`; its evidence-only block excludes the mandatory generation prefix. OpenAI counting uses [the input-token endpoint](https://developers.openai.com/api/reference/python/resources/responses/subresources/input_tokens/methods/count). The generation's reported input count must match preflight. Identical message content does not imply identical rendered tokens or equal inference compute across the models.

This is a separate Python diagnostic. It bypasses native admission, journaling and episode accounting. It does not verify an OpenAI production adapter or establish total application costs. Input/output usage, transport failures and elapsed time are recorded separately.

## Source-aware judgments

Both Qwen and Sol judge every completed answer, including their own, in fresh independent requests. Judge input includes the question, reference, candidate answer and original evidence. Answerer identity is omitted. The reference identifies expected facts; it is explicitly excluded as grounding evidence.

The entire completed judgment must be a JSON object with exactly four unique keys, each containing `yes`, `no` or `unknown`:

- `question_answered`: all requested parts, scope and temporal constraints are addressed.
- `reference_consistent`: essential expected facts agree with the answer.
- `all_claims_supported`: every material claim and cited relationship follows from the supplied original records.
- `pack_sufficient`: the records contain the necessary facts, antecedents and chronology, assessed independently of the candidate answer.

Duplicate keys, fences, extra text, missing/extra fields, booleans and malformed nested provider responses are refused. Operational failure is unknown/unscored and retains the twenty-attempt denominator. Grounded success requires all three answer fields to be `yes`; sufficiency is reported separately. A judge's sufficiency labels for the same pack must also be compared across answerers to expose inconsistent evaluation.

Report the two-by-two answerer/judge matrix, all field disagreements and sufficiency inconsistencies. These are uncalibrated model opinions. Both model families judge their own answers, and separate requests do not eliminate family correlation. There is no human adjudication, representative accuracy estimate or independent real-answer calibration. Do not pool twenty labels as independent quality observations or equate this rubric with earlier source-blind benchmark acceptance.

## Verification and receipts

Eleven portable synthetic tests cover strict output parsing, malformed nested provider shapes, usage preservation on failed responses, reasoning/formatting bounds, source/scorer separation, evidence rendering, destination refusal and rejection of an altered or falsy reuse parent before network access. Independent source review checked the repaired runner before API execution. Independent terminal review reconstructs every answer, judge and count request, original-source closure, copied capture, response/answer hash, provider usage and count equation, spending inventory and reported label comparison. Both attempts' artifact inventories remain unchanged during review. This authenticates the execution and labels; independent semantic adjudication remains unrun. The native experimental 3,887-check receipt remains separate and predates the unbuilt v1-default gating edit.

| Frozen artifact | SHA-256 |
|---|---|
| Answering inputs | `f1b2365bd8d02d74a2a2974904d04597ff973b64ec40d70f677c9a3c868f82dd` |
| Scorer-only inputs | `0dc6bdc96c42c1d35fc54ca03a72e2eb6f053097e7c8253143145c2952a17298` |
| Input manifest | `8f8c8ec7c5db1dd552519b7c7ef6118dd962ad4fe20b4cc2c40e140c5e91a9c9` |
| Independent mechanical input verification | `e5560e3050bf8f5bbfdc6f1842a5082bf1b90bf4ddec87ab0441893d970f2f56` |
| Prior-context availability inspection | `69143365079c45774bec321e46d402e281651435512dd29618eec3ba5336d7d2` |
| Terminal v1 runner | `4815f25e1bd31b4ed5528b66df17eeb35a69c03fa2466f1c9e8a2da0b220730a` |
| Terminal v1 report | `36d0abf8f22a35fb637748f2210f03d64cfe88d2c098cf4b45c19c0d56fc9d46` |
| Independent v1 capture verification | `7bee9496277ff7170b950f796e4375a4ded02b4460668e332ac0ab6e66dbeaab` |
| Terminal v2 runner | `f8942c31c3eac923572b6a07ee6a0d51d1545586a1ec5b4638c5b5947bc41f3b` |
| Terminal v2 report | `3906102b20bfe7a4981900fc5d50580badeaa9ed8bc8288ebd21635d37d0e645` |
| Independent terminal v2 verification | `7fbe861f073c4ead9eaa74bd9466bf9cba4473e059cbf1fd831698ad0c2e65f0` |

Inputs and private captures remain under ignored `.build/evaluation` paths. Both attempts retain frozen runner copies. The completed comparison uses the exact five original Sol answers; none were regenerated after observing their labels.

## Completed diagnostic

All ten logical answers and twenty judgments completed within their declared count/output checks. V2 made exactly twenty new generation calls and twenty-five count calls. V1 made ten successful Sol generation calls, fifteen successful Sol counts and ten failed Qwen counts. Cumulative execution contains thirty unique generation calls and fifty count attempts across eighty HTTP attempts. The original ten HTTP 404 failures remain in the receipt inventory; they are not ten generation failures or new quality observations.

Grounded success requires `yes` on all three answer fields. Each cell contains five declared judgments:

| Answerer | Qwen judge | Sol judge |
|---|---:|---:|
| Qwen | 2/5 | 3/5 |
| GPT-6.1 Sol | 4/5 | 4/5 |

Both judges accept both models on `1b9b7252` and `4baee567`, two prior missing-target failures. Both accept Sol on `54026fce` and `gpt4_70e84552`, the cases whose experimental native contexts contained all annotated positives. For Qwen, the former has conflicting reference-consistency labels; the latter is rejected by both, with Sol also marking unsupported claims. These are diagnostic model opinions about new clean-pack requests. Exact prior native-context bodies are unavailable, so the experiment cannot isolate answerer replacement on unchanged native inputs.

Five individual fields disagree across four case/answer pairs:

| Case | Candidate answerer | Field | Qwen judge | Sol judge |
|---|---|---|---|---|
| `51c32626` | Qwen | Pack sufficient | Yes | No |
| `51c32626` | Sol | Question answered | Yes | No |
| `54026fce` | Qwen | Reference consistent | No | Yes |
| `gpt4_70e84552` | Qwen | Question answered | Yes | No |
| `gpt4_70e84552` | Qwen | All claims supported | Yes | No |

The same frozen `51c32626` pack receives `yes` from Qwen when evaluating Qwen's answer and `no` when evaluating Sol's answer. Sol labels it insufficient for both answers. Pack sufficiency was supposed to be independent of the candidate answer; this inconsistency directly exposes an evaluation defect. Neither answer achieves grounded success on this case. It cannot establish an answerer limit from verified sufficient evidence. The other four packs receive unanimous `yes` sufficiency labels, which remain uncalibrated model judgments.

### Usage and latency

The fifteen unique Sol generations comprise five answers and ten judgments. Their observed usage totals 88,342 input tokens, 1,000 output tokens including 124 reasoning tokens, and zero cached input tokens. At the verified standard prices of $2 per million input tokens and $10 per million output tokens, this is an estimated **$0.186684** for generation. The estimate is not a billing statement or native application cost. See [official pricing](https://developers.openai.com/api/docs/models/gpt-6.1-sol). Count requests, local compute, retrieval and application work are reported separately.

The fifteen local Qwen generations consume 101,756 reported input tokens and 1,654 reported output tokens, with zero reported reasoning or cached input tokens. No dollar estimate is assigned to local execution.

For the five answer calls alone, generation-operation elapsed time has a median of 3.405 seconds for Sol (range 2.755–5.781) and 9.847 seconds for Qwen (range 2.606–24.408). These measurements exclude counting and native context preparation. They include provider/network waiting, response capture and flushing, frozen-input validation and local warm-up effects; five selected calls do not establish comparative production latency.

### Consequence

Sol performs better on this small diagnostic under both judges. Evidence selection remains a demonstrated problem, and clean evidence also reveals answerer and judging limitations. More retrieval hits cannot by themselves establish reliable answering. Next work should authenticate sufficient complete-exchange packs, retain disagreement cases for independent semantic calibration, and test relevance/token-aware exchange selection on fresh cases. An OpenAI production adapter, broader architecture, optional trees and further scoped-policy work remain outside this diagnostic.

This diagnostic is a record. The OpenAI route is retired for evaluations; future remote answering or judging runs use [Vertex AI in the `llm-train` project](DESIGN-REPAIR-PLAN.md#remote-evaluation-provider), which needs a Vertex adapter before this runner can be reused. The synthetic contracts still run offline:

```sh
python3 scripts/test_answerer_controls.py
```
