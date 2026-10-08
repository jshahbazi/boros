# Judge calibration (P4) preparation

Prepared October 8, 2026 for work package P4 of the [design repair plan](DESIGN-REPAIR-PLAN.md#p4-judge-calibration). This record separates three kinds of statement:

- **Implemented:** `scripts/judge_calibration.py` (inventory, blinded assembly, local adjudication form, scoring, declaration check), `scripts/test_judge_calibration.py` (17 synthetic contracts) and two Vertex declaration templates under `scripts/judge_calibration_declarations/`.
- **Measured:** the inventory counts below and the composition of the assembled set. They are metadata counts. No answer has been adjudicated and no judge has run, so no judge error rate exists yet.
- **Proposed:** the adjudication protocol, the judge prompts, the self-preference handling and the run declarations. None of them has been exercised against a model.

No generation, judge, token-count, access-probe or local model server call was made. No question, reference, evidence, answer or note text appears in this document, in test fixtures or in command output. The tool prints counts, identifiers and hashes only.

## Inventory of saved answers

The tool reads saved captures read-only and writes a metadata-only inventory (run, model, question ID, category, abstention flag, prior judge labels and their source, evidence retention, stratum) to a private file. Searched locations:

- The primary checkout's `.build/evaluation`.
- Worktrees under `.claude/worktrees/*`. Only `boros-design-tests-08c1f8` has an evaluation directory, and it holds retrieval-harness reports with no answers.
- The `codex/native-investigation` worktree at `~/.codex/worktrees/native-investigation/boros/.build/evaluation`. It is a Git worktree of this repository outside `.claude/worktrees`. It holds the only native investigation answer captures, so it was included, read-only.

An attempt is **eligible** when all of these hold: it completed operationally, its answer bytes match the recorded answer digest, the question and reference resolve from the pinned LongMemEval S file (SHA-256 `d6f21ea9…a442`), any run-local reference equals the dataset reference, and its delivered evidence is retained and verified. Native runs retain evidence as byte-range pointers into original messages; every range carries a digest, and every one of them matched. The orientation pilot and the clean-pack controls retain the evidence text itself.

| Run | Answerer | Arms | Rows | Eligible | Evidence retained | Prior labels |
|---|---|---|---:|---:|---|---|
| natural-v2 | Qwen | recent-only, hybrid | 14 | 13 | pointer | none |
| natural-v3 | Qwen | recent-only, hybrid | 14 | 14 | pointer | none |
| natural-v4 | Qwen | recent-only, hybrid | 14 | 14 | pointer | Qwen local QA |
| natural-v5 | Qwen | recent-only, hybrid | 14 | 13 | pointer | Qwen local QA |
| adjacent-v1 | Qwen | recent-only, hybrid | 14 | 11 | pointer | Qwen local QA |
| independent-v1 | Qwen | recent-only, hybrid | 28 | 28 | pointer | Qwen local QA |
| neighborhood-v1 | Qwen | recent-only, hybrid | 28 | 28 | pointer | Qwen local QA |
| source-controls-v1 | Qwen | oracle source pack | 6 | 5 | pointer | Qwen local QA |
| openai-controls-v2 | Qwen and GPT-6.1 Sol | clean pack | 10 | 10 | text | Qwen and Sol, source-aware four-field rubric |
| orientation-zoom-v1 | GPT-6.1 Sol | lexical exchange, inspection, orientation | 90 | 43 | text (58 packs) | Sol QA, Sol source-only sufficiency, Sol support, JevK5 MCP |
| native-local-trial-v2 | Qwen | recent-only, investigation | 6 | 6 | pointer | JevK5 MCP |
| native-hundred-v1 | Qwen | investigation | 100 | 7 | pointer | JevK5 MCP |
| Total | | | 338 | 192 | | |

All 146 ineligible rows failed operationally or were never run: 90 unattempted and 3 failed or interrupted native-hundred questions, 47 orientation attempts without answers (provider HTTP 429), and 6 failed native LongMemEval attempts. No eligible-looking row was lost to a hash, range or reference mismatch.

Not included: `longmemeval-natural-v1` (recorded invalid), `native-local-trial-v1` (the failed trial), the OpenAI controls v1 attempt (v2 reuses its Sol answers, so including it would duplicate them), and DevGPT, BEAM and public-chat pilots. Those pilots use exact task scoring on non-LongMemEval material, not a reference-answer judge. No answer authored by Claude Opus or Claude Sonnet exists in any capture.

Eligible rows by answerer: 144 Qwen, 48 Sol, 0 Anthropic. By category: abstention 34, knowledge update 31, multi-session 34, assistant recall 29, preference 16, user recall 22, temporal reasoning 26. They cover 45 distinct questions. Prior label rows among eligible attempts: Qwen local QA 99, JevK5 MCP 56, Sol QA 39, Sol source-only sufficiency 29, Qwen source-aware 10, Sol source-aware 10.

### Strata

Each eligible row gets one stratum by precedence:

1. **Abstention:** the dataset marks the question unanswerable.
2. **Correct-plus-unsupported:** a prior judge accepted the answer against the reference, and either a support judge marked a material claim unsupported, or a source-only judge marked the pack insufficient.
3. **Incomplete evidence:** an answerable question whose delivered evidence missed at least one annotated positive turn.
4. **Accepted** if any prior judge accepted the answer, **rejected** if every prior judge rejected it, and **unlabeled** if no prior verdict exists.

Abstention and incomplete evidence use only dataset and delivery metadata. Accepted, rejected and correct-plus-unsupported cannot be defined without prior labels. Within every stratum, the order is a seeded SHA-256 of the run, question and arm key. It never reads answer text, reference text or label values. In that sense the selection is answer-blind "where possible".

| Stratum | Eligible rows | Distinct questions | After duplicate-answer removal |
|---|---:|---:|---:|
| Accepted | 61 | 30 | 59 |
| Rejected | 10 | 6 | 10 |
| Abstention | 34 | 9 | 29 |
| Incomplete evidence | 82 | 20 | 68 |
| Correct-plus-unsupported | 2 | 1 | 2 |
| Unlabeled | 3 | 3 | 3 |

Most incomplete-evidence rows are recent-only answers, which by construction lack historical evidence.

## Assembled calibration set

Implemented and generated, not yet adjudicated. Command, using seed `boros-p4-judge-calibration-v1-20261008`:

```sh
python3 scripts/judge_calibration.py assemble \
  --seed boros-p4-judge-calibration-v1-20261008 \
  --evaluation-root /Users/johnshahbazian/development/boros/.build/evaluation \
  --evaluation-root /Users/johnshahbazian/.codex/worktrees/native-investigation/boros/.build/evaluation \
  --dataset /Users/johnshahbazian/development/boros/.build/datasets/longmemeval-98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json \
  --output .build/judge-calibration/set-v1-20261008
```

Selection rules:

- The quota is 10 per stratum and the minimum is 50 items.
- No question contributes more than 2 items.
- Identical answers to the same question are removed.
- Strata are taken round-robin, rarest first. Remaining slots are filled round-robin across strata that still have candidates, with unlabeled rows last.
- The final item order is a separate seeded hash, so an item's position does not reveal its stratum.

| Property | Value |
|---|---|
| Set ID | `jc-9adfaeeb572b8380` |
| `items.json` SHA-256 | `44c998eaf7a93d43c844da2b4be87940853e40c40909197aecd0f7eda871f833` |
| Items / distinct questions | 50 / 32 |
| By stratum | accepted 13, incomplete evidence 13, abstention 13, rejected 8, correct-plus-unsupported 2, unlabeled 1 (10 of these are fill items) |
| By category | abstention 13, multi-session 10, knowledge update 6, assistant recall 6, temporal 6, preference 5, user recall 4 |
| By answerer | Qwen 35, Sol 15, Anthropic 0 |
| Shortfalls | correct-plus-unsupported 8, rejected 2 |
| Identifier substitutions in item text | 88 |
| Answers mentioning a model or vendor name | 0 |

Private files, all mode `0600` in `0700` directories and ignored by Git (`git check-ignore` confirms `.build/`):

- `.build/judge-calibration/set-v1-20261008/items.json`: the blinded items.
- `.build/judge-calibration/set-v1-20261008/key.json`: the unblinding key, with run, arm, model, family, stratum, prior labels and delivery facts.
- `.build/judge-calibration/set-v1-20261008/adjudication-form.html`: the local form.
- `.build/judge-calibration/set-v1-20261008/manifest.json`: metadata, counts and hashes.
- `.build/judge-calibration/inventory-20261008/inventory.json`: metadata only.

The form and the items contain private history. Keep them local: never commit, publish, upload or attach them.

### Blinding

Each item carries only these fields: an opaque `item-NNN` ID, the question, question date, category, an "unanswerable by design" flag, the reference, the evidence and the answer.

- Evidence entries are relabelled `E1…En` and listed in original chronological order with role and date. Partial entries carry only the delivered byte ranges.
- The following are removed from item text: model, run, arm, stratum, prior labels, original question IDs (including the `_abs` answerability cue), event IDs, `answer_…` session IDs and 64-hex source IDs.
- Event IDs cited inside answers are rewritten to the matching `E` label, or to `[source]` when the cited event was not delivered.
- Assembly refuses to write a set if a structural check finds any such leak.

Residual limits:

- Writing style can reveal the answerer.
- A recent-only pack's small, recent-only composition can reveal its arm.
- Citation markers in native answers refer to the original rendering, not to the `E` labels.
- Orientation abstention answers were generated after their answerer saw a leaked answerability cue ([orientation pilot](ORIENTATION-ZOOM-PILOT.md)). Those answers remain valid objects to adjudicate, but their prior acceptance is not clean evidence about the answerer.

### Filling the shortfalls

The plan asks for every listed stratum. Two fall short:

- **Correct-plus-unsupported (2 of 10, one question).** Prior support labels exist only for the 43 answered Sol orientation attempts and the 10 clean-pack answers. Options, in order of preference:
  1. Treat the stratum as a sampling aid, not the measure. Every one of the 50 items is adjudicated with the unsupported-claims flag, so the set measures how often correct-but-unsupported answers occur and how each judge treats them, whatever the sampling stratum.
  2. Add reviewer-constructed items: take answers adjudicated correct and append one plausible claim the evidence does not support. Report these as a separate constructed stratum, never pooled with natural answers.
  3. Add natural cases from future source-aware runs (P5 reader answers), adjudicated in a set extension.
- **Rejected (8 of 10).** Ten rejected rows exist across six questions, and the per-question cap admits eight. Raising `--max-per-question` to 3 for a second set adds correlated items. The incomplete-evidence and abstention strata already supply many expected rejects, so false-accept denominators do not depend on this stratum alone.

Enlarging the set is a rerun of `assemble` with a new seed or a higher `--per-stratum` into a new directory. Existing directories are never overwritten.

## Adjudication protocol (proposed)

The user, or a reviewer the user designates, uses the form:

1. Open the form in a desktop browser. It is a single self-contained file. Its Content-Security-Policy forbids network connections, external scripts, styles, images and form submission.
2. For each item, read the question, its date, the category, the reference and the evidence. The answer stays hidden.
3. Record **pack sufficiency**:
   - *Sufficient:* the evidence contains every fact, antecedent and date needed to reach the reference answer. For an unanswerable question, sufficient means the evidence supports concluding that the information is absent.
   - *Insufficient:* the evidence lacks something needed.
   - *Unsure:* use sparingly.
4. Reveal the answer. Revealing is enabled only after a sufficiency choice. If sufficiency is changed after the reveal, both values are kept and reported.
5. Record the **answer verdict**:
   - *Accept:* the answer addresses every part of the question, agrees with the reference on the essential facts, and makes no material claim the evidence does not support. For an unanswerable question, accept means the answer declines or states that the information is unavailable.
   - *Reject:* any of those conditions fails.
   - *Unsure:* the item is excluded from rate denominators and counted separately.
6. If the only reason for a reject is an unsupported claim in an answer that agrees with the reference, also tick **unsupported claims**. This lets scoring compute a reference-only variant.
7. Add an optional note, export decisions, and save the export under `.build/judge-calibration/`.

Decisions autosave in browser local storage when it is available. Export regularly; "Clear saved progress" removes the browser copy. Notes can contain private text, so exports are private files.

Open rubric decision for the user: the upstream LongMemEval judge tolerates off-by-one day errors on temporal durations and accepts preference answers that use the user's information without every rubric point. The protocol above does not state either tolerance. Decide before adjudicating whether to apply them, and record the decision with the set.

## Scoring (implemented)

```sh
python3 scripts/judge_calibration.py score --set .build/judge-calibration/set-v1-20261008 \
  --adjudications .build/judge-calibration/adjudications-jc-9adfaeeb572b8380.json \
  --labels vertex-opus=.build/judge-calibration/labels-vertex-opus.json
```

Score inputs:

- **Adjudications:** the form export. The set ID and the items hash must match.
- **Label files:** one per judge, format `boros-judge-calibration-labels-v1`. Each item has `verdict` (`accept`, `reject` or `unknown`) and optional `sufficiency` (`sufficient`, `insufficient` or `unknown`). Replicates may be given as a list; a majority vote decides, ties become `unknown`, and replicate agreement is reported.

Score output:

- **Candidate judge columns.** There is always one column for each of the five candidates: `jevk5-mcp`, `qwen-local`, `vertex-opus`, `vertex-sonnet` and `jev-hosted`. A column reports "no labels supplied" until its label file exists.
- **Historical label columns.** These are drawn from the key: `qwen-local-qa`, `qwen-source-aware`, `jevk5-mcp-qa`, `sol-qa`, `sol-source-aware` and `sol-sufficiency`. Each column states what input that judge saw. Historical labels cover different subsets: Qwen local QA labels only native Qwen answers, and JevK5 labels only orientation and native investigation answers. Their rates are therefore not comparable with each other. Only a rejudging of the whole set with identical items gives comparable candidate rates.

Definitions:

- **False-accept rate:** judge accepts among items adjudicated reject.
- **False-reject rate:** judge rejects among items adjudicated accept.
- **Error rate:** false accepts plus false rejects, over all compared items.
- **Intervals:** every rate carries a 95 percent Wilson score interval (z = 1.96).
- **Exclusions:** adjudicated-unsure items and judge `unknown` labels are excluded from denominators and counted.
- **Breakdowns:** rates are reported overall, by category (abstention is its own category), by sampling stratum, and by answerer relation (same model, same family, other family).
- **Variants:** *grounded* uses the recorded verdict. *Reference-only* counts an adjudicated reject with the unsupported-claims flag as an accept. The reference-only variant is the fair comparison for reference-only judges such as the upstream LongMemEval QA prompt. The grounded variant is the product measure.
- **Sufficiency agreement:** for each judge with sufficiency labels, agreement with adjudicated sufficiency on items where both are definite, with a Wilson interval, Cohen's kappa and the confusion counts.
- **Separability:** pairwise, whether two judges' grounded overall error intervals fail to overlap. Plan P4 step 2 says to enlarge the set when they overlap.

At 50 items, a rate near 50 percent has a Wilson half-width of about 13 to 14 points. Per-category cells hold 4 to 13 items, so per-category intervals will be wide. Report them, but do not treat them as decisive.

## Candidate judges

| Judge | Route | State |
|---|---|---|
| `jevk5-mcp` | Local `JevK5-4B-v0.3-Q8_0` through the supplied mcpme slot ([record](JEVK5-SAVED-QA.md)) | The saved-answer adapter exists for the orientation report only. Rejudging the set needs an adapter over `items.json`. Local model calls need the user's go-ahead. |
| `qwen-local` | Local selected Qwen server | The existing graders bind to specific run reports. Rejudging the set needs an adapter over `items.json`. |
| `vertex-opus` | Vertex AI, `llm-train-482420`, `global`, `claude-opus-5-5` | Adapter `scripts/vertex_anthropic.py` exists. Template `scripts/judge_calibration_declarations/vertex-opus.template.json`. A set runner is not built. |
| `vertex-sonnet` | Vertex AI, `llm-train-482420`, `global`, `claude-sonnet-5-5` (enabled per the user; not verified here) | Template `scripts/judge_calibration_declarations/vertex-sonnet.template.json`. The adapter pins `MODEL = "claude-opus-5-5"` and its model-echo check, so a Sonnet run first needs the adapter parameterized by model, with synthetic tests. |
| `jev-hosted` | Hosted Jev from typesafe.ai | Not usable yet; see below. |

### Hosted Jev

The user has a hosted Jev account. It is a different route from the local JevK5 MCP slot, and it is proposed as a fifth, fast and cheap candidate. The [public announcement](https://typesafe.ai/blog/introducing-system-one-models-and-jev) was read for its API shape. It describes structured outputs defined in advance, with calibrated probabilities and confidence. It claims 70 to 500 milliseconds end to end, lists input at $0.042 per million tokens with output free (the page itself says the price may be subsidized), and describes early access. It does not publish the request schema, authentication, context limit or data retention terms. Those are on separate docs, console and policy pages, which were not read.

Before hosted Jev can be used:

1. **A new remote provider.** The plan currently routes all remote evaluation through Vertex AI ([remote evaluation provider](DESIGN-REPAIR-PLAN.md#remote-evaluation-provider)), so the plan needs an amendment admitting hosted Jev.
2. **Its own adapter, contract and synthetic tests,** with the same standard as `vertex_anthropic.py`: pinned endpoint, refused redirects and proxies, bounded responses, fixed error codes, and no logging of request or response bodies.
3. **Review of its data retention and privacy terms** before any history leaves the machine.
4. **A declared price and spending cap per run,** never assumed from the blog.
5. **The user's explicit authorization** for the run.
6. **Keychain storage for the credential.** Per `AGENTS.md`, the API key belongs in the macOS Keychain, not a plaintext file. Move it there before an adapter is written. The adapter should read it only from the Keychain. No client was built or run, and this repository references no key or key location.

Family note: JevK5 and hosted Jev likely share a model family. The score's family relation treats them as one family, `jev`. Neither has authored answers, so this affects only future sets.

## Vertex run declarations (templates)

`scripts/judge_calibration_declarations/vertex-opus.template.json` and `vertex-sonnet.template.json` contain no private data.

Fixed fields:

| Area | Value |
|---|---|
| Route | Project `llm-train-482420`, location `global`, the model ID, `anthropic_version vertex-2023-10-16` |
| Authentication | Application Default Credentials, no API key |
| Sampling | Provider default: no temperature or other sampling parameter, no extended thinking |
| Counting and cost gate | Count tokens before generation; refuse if counted input times declared prices exceeds the cap |
| Access probe | One unbilled access probe before the first generation |
| Retries and stops | No automatic retries; stop on the first infrastructure failure |
| Requests | Two stages per item (sufficiency without the answer, then verdict); 3 replicates; at most 256 output tokens per request; 2 concurrent requests |
| Prompts | Hash of the frozen judge prompts (`boros-judge-calibration-prompts-v1`, SHA-256 `cc41c72e0ce74b22d52713a77379f9ab48fef17624414e48a93ded94d5d0080f`) |

Required fields the user fills:

- Authorizer and date.
- Calibration set ID, items hash and item count.
- Input and output prices per million tokens, with their source and verification date.
- Spending cap.
- Maximum generation and count requests.
- Labels output path.

`python3 scripts/judge_calibration.py check-declaration FILE --set .build/judge-calibration/set-v1-20261008` lists every unfilled or inconsistent field. It refuses any `temperature`, `top_p`, `top_k` or `seed` key, a changed route or model, a disabled count gate or cost gate, retries, a non-positive cap or price, a prompt hash that differs from the code, and a set that differs from the manifest. Copy the template to `.build/` before filling it, because a filled declaration holds the user's authorization record.

Scale, not a cost estimate: the 50 items render to about 1.6 MB of sufficiency requests and 1.7 MB of verdict requests per replicate, with a largest request of 60 KB. Exact token counts come only from the free count endpoint at run time, and prices must be declared, not assumed.

## Self-preference

Measured state: the set contains 35 Qwen-authored and 15 Sol-authored answers, and no Anthropic-authored answer exists in any capture.

- **Qwen as judge** grades its own answers on most of its historical labels. The score reports its rates on same-model and other-family answers separately. The 15 Sol answers make the split testable, with wide intervals.
- **Opus** is a P4 candidate judge and the planned P5 reference reader. Its P4 error rates are measured only on Qwen and Sol answers. They are not valid for grading Opus-authored answers, and the score marks Anthropic judges' self-preference as untestable on this set. P5 must not grade Opus reader answers with Opus.
- **Sonnet judging Opus answers** removes same-model grading but not same-family bias.

Proposed measurement, as a P4 extension once P5 or another authorized run produces Anthropic-authored answers:

1. Assemble an extension set with the same tool, with Opus-authored and, if any exist, Sonnet-authored answers stratified as above. Use at least 20 per author model so a same-family split has a usable interval, and mix in the same number of non-Anthropic answers to the same questions.
2. Adjudicate it blind with the same form.
3. Score Opus and Sonnet on it. Compare false-accept rates on own-model, same-family and other-family answers: Opus on Opus, Sonnet on Opus and Sonnet, and both on Qwen and Sol.
4. Until that comparison shows no material same-family excess, grade P5's Opus reader answers with the best calibrated non-Anthropic judge, and report the Sonnet-on-Opus result separately with its same-family caveat. Human adjudication of a sample of P5 Opus answers is the fallback when no non-Anthropic judge has acceptable error rates.

## What the user must do and authorize

To start P4 adjudication now (no model calls):

1. Decide the two open rubric points: the temporal off-by-one and preference tolerances, and whether to adjudicate the two-item correct-plus-unsupported stratum as is or add reviewer-constructed items.
2. Open `.build/judge-calibration/set-v1-20261008/adjudication-form.html` locally, adjudicate the 50 items, and export the decisions into `.build/judge-calibration/`. A designated reviewer may do this instead; the export records the adjudicator name.

To run judges (each needs separate authorization; none is built to run yet):

1. **Vertex Opus.** Authorize a set runner on `vertex_anthropic.py` (not built). Fill and check the Opus declaration (prices, cap, request limits, set hashes), then authorize the run, including its unbilled access probe and free counting pass.
2. **Vertex Sonnet.** Authorize parameterizing the adapter by model, with tests, before the same steps with the Sonnet declaration.
3. **JevK5 MCP and Qwen local.** Authorize set adapters for both and their local model calls, so all candidates are measured on identical items.
4. **Hosted Jev.** Move the key into the Keychain. Approve a plan amendment admitting the provider. Authorize the adapter, its contract and tests, and the data-terms review. Then authorize a declared, capped run.

After labels exist, `score` produces the rates. P4 step 3 then selects the judge or ensemble with the lowest grounded error, and the earlier LongMemEval local labels are annotated with their judge's measured rates.

## Verification

- `python3 scripts/test_judge_calibration.py`: 17 synthetic contracts, all passing. They cover:
  - strata precedence;
  - seeded selection determinism and independence from input order;
  - selection unchanged when answer text or label details change;
  - quota, shortfall, per-question cap and fill counts, and removal of duplicate answers;
  - blinding of model identity, run, arm, prior labels, `_abs`, event, session and hex IDs, plus the leak detector;
  - private file modes, no-clobber output and the `.build` destination guard;
  - the form's network-free policy and script-injection escaping;
  - Wilson interval values, kappa and majority vote;
  - false-accept, false-reject, reference-only, replicate, sufficiency and self-preference scoring, and refusal of mismatched inputs;
  - sufficiency prompts that omit the answer;
  - both declaration templates and their checks;
  - native byte-range resolution with digest verification.
- The form's reveal gate, change-after-reveal record, navigation, autosave and export format were exercised in a browser against a synthetic set, which was then deleted. The private set was not opened in a browser by this preparation.
