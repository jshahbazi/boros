# Judge calibration (P4) preparation

Prepared October 8, 2026 for work package P4 of the [design repair plan](DESIGN-REPAIR-PLAN.md#p4-judge-calibration). This record separates three kinds of statement:

- **Implemented:** `scripts/judge_calibration.py` (inventory, blinded assembly, local adjudication form with the faithful field, form regeneration, v1 and v2 adjudication loading with revision checks, scoring, declaration check, frozen judge prompts, Vertex reply schemas), `scripts/test_judge_calibration.py` (21 synthetic contracts), the [judge runner](#judge-runner-implemented-not-run) `scripts/judge_calibration_run.py` with `scripts/test_judge_calibration_run.py` (22 synthetic contracts), `scripts/vertex_anthropic.py` parameterized by model with opt-in structured outputs and thinking controls (15 synthetic contracts), and six declaration templates under `scripts/judge_calibration_declarations/` (version 2 for the two Vertex judges, version 1 kept for runs made under it).
- **Measured:** the inventory counts below, the composition of the assembled set, and the runner's dry-run counts over that set. They are metadata counts. Since October 9, 2026 also: the user's [human adjudication](#human-adjudication-measured-october-9-2026) of all 50 items, its [revision](#revision-of-october-9-2026), the earlier judges' error rates against the revised file, and one live version 1 Vertex Sonnet pass. No candidate judge has a calibrated rate from a complete run yet.
- **Proposed:** the adjudication protocol, the self-preference handling and the filled run declarations. The runner and its prompts have been exercised only against fake transports, never against a model.

No generation, judge, token-count, access-probe, MCP or local model server call was made, including during the dry runs. No question, reference, evidence, answer or note text appears in this document, in test fixtures or in command output. The tools print counts, identifiers and hashes only.

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

## Adjudication protocol

Used by the user for the October 9, 2026 adjudication; the verdict rubric and the faithful field were settled by the user's decisions of October 9, 2026. The user, or a reviewer the user designates, uses the form:

1. Open the form in a desktop browser. It is a single self-contained file. Its Content-Security-Policy forbids network connections, external scripts, styles, images and form submission.
2. For each item, read the question, its date, the category, the reference and the evidence. The answer stays hidden.
3. Record **pack sufficiency**:
   - *Sufficient:* the evidence contains every fact, antecedent and date needed to reach the reference answer. For an unanswerable question, sufficient means the evidence supports concluding that the information is absent.
   - *Insufficient:* the evidence lacks something needed.
   - *Unsure:* use sparingly.
4. Reveal the answer. Revealing is enabled only after a sufficiency choice. If sufficiency is changed after the reveal, both values are kept and reported.
5. Record the **answer verdict**. The verdict means agreement with the reference under the LongMemEval [category tolerances](#category-tolerances-user-decision-october-8-2026):
   - *Accept:* the answer addresses every part of the question, agrees with the reference on the essential facts, and makes no material claim the evidence does not support. For an unanswerable question, accept means the answer declines or states that the information is unavailable.
   - *Reject:* any of those conditions fails. A decline ("no record of that") on an answerable question is a reject, even when the delivered evidence lacked the answer; pack sufficiency, not the verdict, records that retrieval failure.
   - *Unsure:* the item is excluded from rate denominators and counted separately.
6. If the only reason for a reject is an unsupported claim in an answer that agrees with the reference, also tick **unsupported claims**. This lets scoring compute a reference-only variant.
7. Record **faithful to the evidence**: whether the answer is honest about and consistent with the delivered evidence, independent of the reference.
   - *Yes:* for example an honest decline on insufficient evidence, or an honest undercount that reports what the evidence shows. These are faithful even though their verdict is reject.
   - *No:* the answer contradicts the evidence, or claims something the evidence does not show.
   - *Unsure:* use sparingly.

   Faithful is recorded after the reveal, next to the verdict. It is reported by `score` but never enters judge error rates: judges are calibrated on the verdict only. A decision without it (`null`) means not adjudicated.
8. Add an optional note, export decisions, and save the export under `.build/judge-calibration/`.

Decisions autosave in browser local storage when it is available. Export regularly; "Clear saved progress" removes the browser copy. Notes can contain private text, so exports are private files. The form counts an item complete only when sufficiency, verdict and faithful are all recorded, and reports items that still need faithful. It imports v1 and v2 exports (a v1 decision imports with faithful unset) and always exports v2. An imported revision block is not carried into a new export.

### Adjudication format

Exports and revisions are JSON files with `format`, `set_id`, `items_sha256`, `adjudicator`, `exported_at` and `decisions` (item ID to decision). A decision holds `sufficiency`, `verdict`, `unsupported_claims`, `note`, `sufficiency_at_reveal` and `revealed`.

- **`boros-judge-calibration-adjudications-v1`:** the first form's export. It has no `faithful` key; a v1 file that carries one, or a `revision` block, is refused (`adjudication_faithful_requires_v2`, `adjudication_revision_requires_v2`).
- **`boros-judge-calibration-adjudications-v2`:** adds `faithful` per decision, one of `yes`, `no`, `unsure` or `null` (`adjudication_faithful_invalid` otherwise). The current form exports this format.
- **Revision block (v2 only, optional):** a revised file applying later rubric decisions carries `revision` with `of_export_sha256` (the SHA-256 of the export it revises), `revised_on` (`YYYY-MM-DD`), `authorized_by`, `applied_by`, `rubric`, optional `faithful_coverage`, and a non-empty `changes` list. Each change names an `item`, an optional `reason`, and one or more changed fields among `sufficiency`, `verdict`, `faithful`, `unsupported_claims` and `note`, written `"from->to"` (`null`, `true` and `false` as words), a bare `"to"` for a field the original did not carry (faithful in a v1 original), or `"changed"` for a note.

`score` checks a revision block on every load: every listed item exists once, every value is valid, and every listed target equals the revised file. With `--original-adjudications FILE` it also requires the original's hash to equal `of_export_sha256`, the original to be a valid export of the same set, and the listed changes to be exactly the difference between the two files: no unlisted change to any decision field (including note text and the form's reveal record), no listed change that did not happen, and every listed source equal to the original. Failures carry fixed codes (`adjudication_revision_original_hash`, `adjudication_revision_unlisted_change`, `adjudication_revision_listed_change_absent`, `adjudication_revision_source_mismatch`, `adjudication_revision_target_mismatch`, `adjudication_revision_change_invalid`, `adjudication_revision_unknown_item`, `adjudication_revision_duplicate_item`, `adjudication_revision_invalid`, and `adjudication_revision_missing` when an original is given for a file without a revision block). Note text is compared but never printed.

To regenerate the current form for an existing set without touching the set directory:

```sh
python3 scripts/judge_calibration.py form --set .build/judge-calibration/set-v1-20261008 \
  --output .build/judge-calibration/form-v2-20261009/adjudication-form.html
```

### Category tolerances (user decision, October 8, 2026)

The user decided that adjudication applies the tolerances built into the pinned upstream LongMemEval judge prompts (`evaluate_qa.py` in the October 6 protocol capture), so human verdicts and runner verdicts grade against the same standard. They apply to the answer verdict only, never to pack sufficiency, and to every item in the set:

- **All answerable categories:** accept a response that is equivalent to the reference or contains all the intermediate steps that lead to it; reject one that gives only a subset of the required information.
- **Temporal reasoning:** an off-by-one error in a count of days, weeks, months or similar units is still correct.
- **Knowledge update:** a response that also mentions earlier, superseded information is correct as long as the updated answer it gives is the required one.
- **Preference:** the response need not reflect every rubric point; it is correct when it recalls and uses the user's personal information correctly.
- **Abstention:** correct when the response identifies the question as unanswerable, for example by saying the information is incomplete or never mentioned.

These tolerances do not relax step 5's support condition: an answer that agrees with the reference only through a claim the evidence does not support is still ticked as unsupported, so the grounded and reference-only variants stay separable.

## Scoring (implemented)

```sh
python3 scripts/judge_calibration.py score --set .build/judge-calibration/set-v1-20261008 \
  --adjudications .build/judge-calibration/adjudications-jc-9adfaeeb572b8380-v2.json \
  --original-adjudications .build/judge-calibration/adjudications-jc-9adfaeeb572b8380.json \
  --labels vertex-opus=.build/judge-calibration/labels-vertex-opus.json
```

Score inputs:

- **Adjudications:** a v1 or v2 export, or a v2 revision (see [Adjudication format](#adjudication-format)). The set ID and the items hash must match.
- **Original adjudications (optional):** the export a revision names; `score` then verifies the revision against it.
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
- **Faithful (reported only):** the adjudication summary gives the number of items with faithful adjudicated, faithful counts overall, by category, by sampling stratum and by answerer family, and a `verdict/faithful/sufficiency` cross-tab (`not_adjudicated` for null). Faithful is not part of any judge rate.
- **Revision:** for a revised file, the summary gives the revised items' IDs, the change count per field, and whether the original was verified. A sufficiency change listed in the revision is not counted as a change after the reveal.

At 50 items, a rate near 50 percent has a Wilson half-width of about 13 to 14 points. Per-category cells hold 4 to 13 items, so per-category intervals will be wide. Report them, but do not treat them as decisive.

## Candidate judges

| Judge | Route | State |
|---|---|---|
| `jevk5-mcp` | Local `JevK5-4B-v0.3-Q8_0` through the supplied mcpme slot ([record](JEVK5-SAVED-QA.md)) | Runner judge `jevk5`, template `jevk5.template.json`. Built and tested with a fake MCP client; not run. |
| `qwen-local` | Selected Qwen model on the loopback mlx-serve endpoint | Runner judge `qwen-local`, template `qwen-local.template.json`. Built and tested with a fake endpoint; not run. |
| `vertex-opus` | Vertex AI, `llm-train-482420`, `global`, `claude-opus-5-5` | Runner judge `vertex-opus`, template `vertex-opus.template.json` (version 2: structured replies, effort `low`, 2,048 output tokens). Built and tested with a fake transport; not run. |
| `vertex-sonnet` | Vertex AI, `llm-train-482420`, `global`, `claude-sonnet-5-5` | Runner judge `vertex-sonnet`, template `vertex-sonnet.template.json` (version 2: structured replies, thinking `between_tools`, 512 output tokens). One live pass ran under the version 1 template ([first Sonnet pass](#first-sonnet-pass-measured-october-9-2026)); version 2 has not run. |
| `jev-hosted` | Hosted Jev from typesafe.ai | Not usable yet and out of the runner's scope; see below. |

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

## Judge prompts (implemented, frozen in code)

Two tasks per item, defined in `JUDGE_PROMPTS` in `scripts/judge_calibration.py` (version `boros-judge-calibration-prompts-v2`). Every declaration pins the hashes below, and `check-declaration` refuses a declaration whose hashes differ from the code.

| Task | Definition | SHA-256 |
|---|---|---|
| Answer verdict | The unchanged upstream LongMemEval category QA prompt (`get_anscheck_prompt` in `src/evaluation/evaluate_qa.py`), the one the earlier Qwen local QA and JevK5 graders used, so labels stay comparable with theirs. Only the hash-pinned pure function executes. Reply `yes` or `no`, mapped to accept or reject. | Upstream file `ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251`; verdict definition `85fa445ad2cda3f103a89828f126834795beffafce991bf676b90531ffc2b40c` |
| Pack sufficiency | New prompt: a system instruction plus the question, its date, the unanswerable-by-design flag, the reference and the evidence, never the answer. Reply exactly `{"sufficiency": "sufficient"}` or `{"sufficiency": "insufficient"}`. | `c604485853f65670fa54599aceb06f5d152a8798b03dc518cca6de73ec76b857` |
| Whole prompt set | Both definitions, including JevK5's structured-choice wrapping | `1cce15660c8a730df03f5654926356715842e5c5bdbb64709a4a1c6cd1990221` |

Consequences of these choices:

- **The verdict judge never sees the evidence.** The upstream prompt is reference-only, so the fair comparison for every runner judge is the score's *reference-only* variant. The grounded variant still applies to the product question of whether a reference-only judge suffices. The upstream prompt also builds in the category tolerances that adjudication applies (see Category tolerances above).
- **Parsing is strict and failures are recorded, never coerced.** A verdict reply is normalized only by trimming whitespace, lowercasing and removing one trailing period, then must be exactly `yes` or `no`. A sufficiency reply must be exactly the JSON object above; a code fence, an extra key or `unsure` is a parse failure. JevK5 answers through its structured choice tool with options `yes` and `no` for both tasks; the verdict request is byte-for-byte the earlier JevK5 saved-answer request shape.
- **Replaced proposal.** The earlier proposed prompt set `boros-judge-calibration-prompts-v1` (SHA-256 `cc41c72e…080f`), which had an evidence-aware verdict prompt, is superseded. The assembled set's manifest still records that earlier hash as a non-binding field; nothing checks it.

### Vertex reply schemas (implemented October 9, 2026, not run)

Version 2 Vertex declarations constrain both replies with structured outputs: the request field `output_config.format` of type `json_schema`. The deprecated `output_format` field is never sent. The schemas are a transport constraint, defined in `REPLY_SCHEMAS` in `scripts/judge_calibration.py` (version `boros-judge-calibration-reply-schemas-v1`), and are separate from the prompts: the prompt texts and the three prompt hashes above are unchanged.

| Stage | Schema | Label mapping |
|---|---|---|
| Verdict | An object with one required string field `answer`, enum `yes` or `no`, `additionalProperties: false` | `yes` to accept, `no` to reject |
| Sufficiency | An object with one required string field `sufficiency`, enum `sufficient` or `insufficient`, `additionalProperties: false`; exactly the object the sufficiency prompt asks for | unchanged |

Reply schema set SHA-256: `089f6abbd4ee62321396ed07e5929cfe30394cfe04f6c44e9512f60bc3fca549`. Version 2 declarations pin it in a `reply_schemas` block, `check-declaration` refuses a mismatch (`reply_schema_hash`), and the run record, the labels file, the dry run and every session report carry it.

The upstream verdict prompt still asks for a bare yes or no; the schema wraps that answer in one JSON field. Whether this changes Sonnet's or Opus's verdicts relative to a bare reply is unmeasured. Parsing of constrained replies stays strict: surrounding whitespace is allowed, and anything else (another key, another value, a duplicate key, a code fence, prose) is the recorded failure `output_off_schema`, never coerced. Version 1 declarations keep the bare-text parsing described above.

## Judge runner (implemented, not run)

`scripts/judge_calibration_run.py` runs one judge per invocation over the frozen set. Hosted Jev is out of scope.

| Judge | Route | Transport |
|---|---|---|
| `vertex-opus`, `vertex-sonnet` | `vertex_anthropic.py` with the model chosen per run; version 2 declarations add structured outputs and per-model thinking controls (below) | Application Default Credentials through gcloud; pinned endpoint, no proxy, no redirect |
| `jevk5` | `StdioMCP` from `jevk5_saved_qa.py`: the supplied `mcpme connect --slot` command, `jevk5_decide` tool | Model identity (ID, SHA-256, profile, context) checked on connect and in every decision; the mcpme executable hash must equal the declared one before connecting |
| `qwen-local` | `http://127.0.0.1:11234/v1/chat/completions`, model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` | Loopback only, no proxy, no redirect; temperature 0, thinking off, model echo checked. Model-instance identity is unobservable through mlx-serve, as recorded in [provider admission](PROVIDER-ADMISSION.md). |

Contract:

- **Input.** `items.json` from `assemble`, verified against the manifest's items hash, set ID and item count, plus a declaration whose `calibration_set` matches the manifest. The runner never opens `key.json`; the tests run it with the key file deleted. Requests are rendered only from the item's question, date, category, unanswerable flag, reference, evidence and answer. The item ID, model identity, run, arm and prior labels are never sent.
- **Two gates.** `--execute` refuses unless `check-declaration` reports no problem (exit code 2, nothing dispatched). Without `--execute` the command is a dry run: it validates the set and declaration, renders every request in memory, writes nothing and prints counts only. The dry run makes no network, Vertex token-count, gcloud, MCP or model-server call.
- **Order and replicates.** Deterministic order: replicate, then item ID, then sufficiency before verdict. Each replicate re-sends the identical request. Vertex replicates sample at the provider default; Qwen replicates at temperature 0 are close to deterministic; JevK5 reports a cache for identical requests, so its replicates can be cache hits, and the report counts them.
- **Vertex cost fence.** Per session: one unbilled access probe (an empty generation body must be refused with HTTP 400; 404 halts as no access), then a free counting pass over every pending request, then a refusal of the whole session if the earlier reservations plus counted input and maximum output for every pending request, at the declared prices, exceed the cap. Before each generation the counted cost is reserved again and the request is refused if the cumulative reservation would exceed the cap. Reservations never decrease, including for failed and interrupted requests, and they carry across resumed sessions.
- **Limits and stops.** Declared request limits are cumulative across sessions. A request whose model-visible prompt exceeds a local judge's declared `max_prompt_characters` is recorded as not dispatched. Infrastructure failures (any HTTP status, transport failure, MCP failure) stop the session when `stop_on_first_infrastructure_failure` is true, which every template sets; otherwise they are recorded. Automatic retries happen only up to the declared `automatic_retries`, which is 0 in every template and must be 0 for Vertex. A model identity mismatch always stops the session.
- **Failures are labels of nothing.** A parse failure, refusal, truncated reply or tool error is recorded per request with a fixed code, and the label stays empty. It is never mapped to accept or reject. Vertex codes under a version 2 declaration: `output_off_schema` (status `parse_failed`), `response_incomplete` (stop reason `max_tokens`, including a reply that is only a thinking block), `refusal` (stop reason `refusal`) and the adapter's other shape codes (status `response_invalid`). A model identity mismatch is checked before the stop reason and halts the session.
- **Vertex reply metadata.** Every Vertex generation receipt records `stop_reason` (a known value, or `other`) and `thinking_tokens` (from `usage.output_tokens_details.thinking_tokens` when the provider reports it, else null). Each session report adds `replies_session` (stop reason counts and summed thinking tokens), `reply_schemas` (null for version 1) and `request_fields` (the field names of the generation and count bodies).
- **Captures and resume.** Each attempt writes `request`, `intent`, `response` and `receipt` files (0600, in 0700 directories) under the run directory. A destination must be fresh unless `--resume` is given, and a resume requires the same declaration hash, set, prompts and request plan. On resume, every earlier attempt is re-authenticated by hash and by re-deriving its label from the captured response; any mismatch refuses the resume. Completed, unparseable and not-dispatched requests are reused, never re-sent. Requests that failed on infrastructure or were interrupted after dispatch are sent again as a new attempt, which counts against the limits and the cap. Declare request limits with headroom above the plan if resumed failures should be possible.
- **Outputs.** Per session: `labels-session-NN.json` and `report-session-NN.json` in the run directory. When every request is terminal, the labels are also written to the declared `outputs.labels_path`, which must be under `.build` and must not exist. Labels use format `boros-judge-calibration-labels-v1` with one `{verdict, sufficiency}` entry per replicate and `judge` set to the score column name (`jevk5-mcp` for the `jevk5` runner judge). Items with no definite label are omitted. The report holds counts by status and stage, fixed failure codes, call counts, token and cost totals, the probe result and hashes; no text. Requests run sequentially, within every template's concurrency limit.

### Vertex request bodies

Field names only. `system` is present for sufficiency requests only. No body carries `temperature`, `top_p`, `top_k`, `output_format` or `budget_tokens`.

| Declaration | Generation body | Count body |
|---|---|---|
| Version 2, `vertex-sonnet` | `anthropic_version`, `messages`, `system`, `max_tokens` (512), `thinking: {"type": "between_tools"}`, `output_config: {format}` | `anthropic_version`, `model`, `messages`, `system`, `output_config: {format}` |
| Version 2, `vertex-opus` | `anthropic_version`, `messages`, `system`, `max_tokens` (2,048), `output_config: {effort: "low", format}`; no `thinking` field | the same as Sonnet |
| Version 1, both | `anthropic_version`, `messages`, `system`, `max_tokens` (256) | `anthropic_version`, `model`, `messages`, `system` |

- **Sonnet 5.5:** omitting `thinking` runs adaptive thinking, and `{"type": "disabled"}` returns HTTP 400. `{"type": "between_tools"}` turns thinking off; it takes no other field and is accepted only at effort `high` or below. The template sends no effort, so Sonnet's default effort, `high`, applies.
- **Opus 5.5:** thinking cannot be disabled (`disabled` and `budget_tokens` both return HTTP 400). The template bounds it with `output_config.effort: "low"` and leaves room for thinking plus the reply in a 2,048-token cap. That cap is a judgment, not a measurement; a reply that still hits it is recorded as `response_incomplete`.
- **Counting:** the count body includes the same `output_config.format`, because structured outputs add input tokens. Thinking and effort do not change the input and are not sent to the count endpoint.
- **Cost fence:** unchanged. Each generation reserves counted input plus the declared maximum output, so the larger caps raise the reservations (see [first Sonnet pass](#first-sonnet-pass-measured-october-9-2026) for an estimate).
- **Adapter defaults:** `vertex_anthropic.payload` and `count_payload` add these fields only when called with the new keyword options (`schema`, `thinking`, `effort`), and validate them per model (`thinking_invalid`, `thinking_unsupported_for_model`, `effort_invalid`, `effort_invalid_with_between_tools`, `output_schema_invalid`). Without them, bodies are byte for byte unchanged, so `evaluate_answerer_controls.py`, `run_memory_investigation.py` and `evaluate_orientation_zoom.py` keep their behavior. `parse_usage` still reports reasoning tokens as zero for those callers; the runner reads thinking tokens through the new `response_metadata`.

### First Sonnet pass (measured October 9, 2026)

One live pass of `vertex-sonnet` under a filled version 1 declaration: 1 replicate, 100 generation requests, 96 count requests, one access probe, observed cost $1.24 (reserved $1.42 against a $4 cap). The run is private under the coordinator worktree's `.build/judge-calibration/runs/vertex-sonnet-r1/`. Metadata only:

| Outcome | Sufficiency | Verdict | Total |
|---|---:|---:|---:|
| Completed | 29 | 42 | 71 |
| `output_unparseable` (stop reason `end_turn`) | 13 | 8 | 21 |
| `response_incomplete` (stop reason `max_tokens`) | 8 | 0 | 8 |

- **Cause.** The version 1 adapter sent no `thinking` field, so Sonnet 5.5 ran adaptive thinking, whose tokens count against `max_tokens`. 20 of 100 replies carried a thinking block; all 8 truncated replies did, with 242 to 256 of their 256 output tokens spent thinking (5 were a thinking block alone, 3 thinking plus partial JSON). Separately, nothing constrained the reply shape: the 21 unparseable replies were prose of roughly 200 to 600 characters rather than a bare `yes`, `no` or JSON object, and 3 of the 8 verdict ones ended in `yes` or `no`. Strict parsing recorded all 29 as failures, as designed.
- **Verified by that pass:** Sonnet access in `llm-train-482420`, its model echo, that omitting `temperature` is accepted, and that responses carry `usage.output_tokens_details.thinking_tokens`.
- **Fix.** Version 2 declarations send `thinking: between_tools` to Sonnet, constrain both replies with the reply schemas, and raise Sonnet's output cap to 512.
- **Reservation estimate (not measured).** That pass counted about 584,000 input tokens over 100 requests. At the prices it declared ($2 input and $10 output per million), version 2 Sonnet reserves about $1.17 of input plus $0.51 of output per replicate, about $5.04 for 3 replicates, before the schema's added input tokens. For Opus at $4 and $20 per million, with a similar token count (its tokenizer may differ), about $2.34 plus $4.10 per replicate, about $19.30 for 3. Vertex prices must be declared from the Vertex price list; these figures only size the cap.

`git check-ignore` confirms that `.build/` is ignored (`.gitignore:2`), so run directories, labels and filled declarations stay out of Git.

### Commands

Run from the checkout whose `.build/judge-calibration/` holds the set. The set was assembled in worktree `agent-a442acfa839e12f30`; copy it with modes preserved (`cp -Rp`) into the checkout that will run the judges. The default `--protocol` is `.build/longmemeval-protocol-20261006/src/evaluation/evaluate_qa.py`, present in the primary checkout; elsewhere pass its path explicitly.

Dry run, per judge (no network, nothing written):

```sh
python3 scripts/judge_calibration_run.py --set .build/judge-calibration/set-v1-20261008 \
  --declaration .build/judge-calibration/declarations/JUDGE.json \
  --output .build/judge-calibration/runs/JUDGE-set-v1
```

Check, then execute (dispatches; needs the user's authorization for that judge):

```sh
python3 scripts/judge_calibration.py check-declaration .build/judge-calibration/declarations/JUDGE.json \
  --set .build/judge-calibration/set-v1-20261008
python3 scripts/judge_calibration_run.py --set .build/judge-calibration/set-v1-20261008 \
  --declaration .build/judge-calibration/declarations/JUDGE.json \
  --output .build/judge-calibration/runs/JUDGE-set-v1 --execute
```

Replace `JUDGE` with `vertex-opus`, `vertex-sonnet`, `jevk5` or `qwen-local`. To continue a halted run of the same declaration, repeat the execute command with `--resume`. Then score, for example:

```sh
python3 scripts/judge_calibration.py score --set .build/judge-calibration/set-v1-20261008 \
  --adjudications .build/judge-calibration/adjudications-jc-9adfaeeb572b8380.json \
  --labels vertex-opus=.build/judge-calibration/labels-vertex-opus.json \
  --labels jevk5-mcp=.build/judge-calibration/labels-jevk5.json
```

### Dry-run counts over the private set (measured)

Run October 8, 2026 against set `jc-9adfaeeb572b8380` (items SHA-256 `44c998ea…f833`), with each unfilled template as the declaration (version 1 for the Vertex judges), from a copy of the set without its key file. Every dry run reported zero network calls and zero files written. Characters are the model-visible prompt characters per request; for JevK5 they include the choice instructions.

| Judge | Items | Replicates | Requests | Distinct requests | Sufficiency chars p50 / max | Verdict chars p50 / max | Largest body (bytes) | Over declared character bound |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `vertex-opus` | 50 | 3 | 300 | 100 | 27,088 / 59,778 | 1,022 / 3,879 | 60,582 | no bound declared |
| `vertex-sonnet` | 50 | 3 | 300 | 100 | 27,088 / 59,778 | 1,022 / 3,879 | 60,582 | no bound declared |
| `jevk5` | 50 | 3 | 300 | 100 | 27,377 / 60,067 | 1,299 / 4,156 | 60,841 | 31 of 50 sufficiency requests (93 of 300) over 24,000 |
| `qwen-local` | 50 | 3 | 300 | 100 | 27,088 / 59,778 | 1,022 / 3,879 | 60,640 | none over 96,000 |

Each Vertex run also needs 100 free count requests, one per distinct request. The templates were reported incomplete, as expected: they lack the fields listed below, and their empty `calibration_set` does not match the manifest.

Version 2 Vertex dry runs, October 9, 2026, same set from a fresh key-less copy, with each version 2 template filled only in `calibration_set`: zero network calls and zero files written. Both report 300 requests (100 distinct), 100 count requests needed, the same prompt characters as above, and reply schema hash `089f6abb…a549`.

| Declaration | Output cap | Largest body (bytes) | Plan SHA-256 | Request fields (verdict) |
|---|---:|---:|---|---|
| `vertex-sonnet` v2 | 512 | 60,835 | `7fa24c7c…bd7` | `thinking` `between_tools`; `output_config` `format` |
| `vertex-opus` v2 | 2,048 | 60,815 | `d652b301…cd99` | no `thinking`; `output_config` `effort`, `format` |

Each still reports only the user-filled fields as problems (authorization, prices and source, cap, request limits, labels path). With the current code, the version 1 Sonnet pass's declaration still passes `check-declaration`, its stored run record matches, and all 100 attempts and 96 counts re-authenticate from its captures (checked read-only), so it remains resumable and verifiable.

JevK5 finding: its context is 8,192 tokens, and the template bound of 24,000 characters is an estimate of about three characters per token, not a measured tokenizer ratio. Under that bound, 31 of the 50 sufficiency requests would be recorded as not dispatched, so JevK5 could produce sufficiency labels for at most 19 items. All 50 verdict requests fit. The real token counts are unverified; JevK5 reports input tokens only after a call.

## Run declarations (templates)

Templates under `scripts/judge_calibration_declarations/` contain no private data. Copy a template to `.build/judge-calibration/declarations/` before filling it, because a filled declaration holds the user's authorization record. New Vertex runs use `vertex-opus.template.json` and `vertex-sonnet.template.json`, format `boros-judge-calibration-vertex-declaration-v2`. The version 1 templates are kept as `vertex-opus.v1.template.json` and `vertex-sonnet.v1.template.json`; `check-declaration` and the runner still accept version 1, with its unconstrained bodies and bare-text parsing, so runs made under it (the first Sonnet pass) can be resumed and verified unchanged. Version 1 has no thinking control and should not be used for new runs.

Fixed in the version 2 Vertex templates:

| Area | Value |
|---|---|
| Route | Project `llm-train-482420`, location `global`, the model ID, `anthropic_version vertex-2023-10-16` |
| Authentication | Application Default Credentials, no API key |
| Sampling | Provider default: no temperature or other sampling parameter |
| Thinking | `execution.thinking`: Sonnet `{"type": "between_tools"}` (thinking off); Opus `"omitted-adaptive"` (no `thinking` field; Opus thinking cannot be disabled) |
| Effort | `execution.effort`: Sonnet `"provider-default"` (not sent; the default is `high`); Opus `"low"` (sent as `output_config.effort`) |
| Reply constraint | `reply_schemas` block: version, SHA-256 and transport of the reply schemas above |
| Counting and cost gate | Count tokens before generation; refuse if counted input and maximum output at the declared prices exceed the cap |
| Access probe | One unbilled access probe per session before the first generation |
| Retries and stops | No automatic retries; stop on the first infrastructure failure |
| Requests | Two stages per item (sufficiency without the answer, then verdict); 3 replicates; at most 512 (Sonnet) or 2,048 (Opus) output tokens per request |
| Prompts | Prompt set `boros-judge-calibration-prompts-v2`, hashes as above |

For version 2, `check-declaration` also refuses: a `thinking` of type `disabled` or `enabled` (`thinking_forbidden`); any `budget_tokens` key anywhere (`forbidden_field`); a thinking value other than the model's fixed one, including `between_tools` with an extra field or on Opus (`thinking_contract`); for Sonnet, effort `xhigh` or `max` with `between_tools` (`effort_above_high_with_between_tools`) and any value outside `provider-default`, `low`, `medium`, `high`; for Opus, an effort that is not explicit (`effort`); an output cap outside 16 to 4,096 for Sonnet or 1,024 to 8,192 for Opus (`output_limit`); the stale version 1 field `extended_thinking` (`stale_field`); and a `reply_schemas` block that differs from the code (`reply_schema_hash`).

Fixed in the local templates (`jevk5`, `qwen-local`): the pinned provider block (JevK5 command, tool and model identity from `jevk5_saved_qa.py`; the Qwen endpoint, model, temperature 0 and thinking off), no automatic retries, stop on the first infrastructure failure, 3 replicates, the prompt hashes, and a `max_prompt_characters` bound (24,000 for JevK5, 96,000 for Qwen, both estimates). Qwen also fixes 16 output tokens per request.

Fields the user fills:

| Field | Vertex | JevK5 | Qwen |
|---|---|---|---|
| `authorization.authorized_by`, `authorized_on` | yes | yes | yes |
| `calibration_set`: set ID `jc-9adfaeeb572b8380`, items hash, item count 50 | yes | yes | yes |
| `outputs.labels_path` under `.build/`, ending `.json` | yes | yes | yes |
| Prices per million input and output tokens, their source and verification date | yes | | |
| `budget.spending_cap_usd` | yes | | |
| `budget.max_generation_requests` (at least 300 for 3 replicates) and `max_count_requests` (at least 100) | yes | | |
| `request_limits.max_requests` (at least 300 for 3 replicates) | | yes | yes |
| `provider.executable_sha256`: SHA-256 of the mcpme executable named in the template's command | | yes | |

`python3 scripts/judge_calibration.py check-declaration FILE --set .build/judge-calibration/set-v1-20261008` lists every unfilled or inconsistent field with a fixed code. It refuses any `temperature`, `top_p`, `top_k` or `seed` key, a changed route, model or local provider pin, a disabled count or cost gate, Vertex retries, replicates outside 1 to 10, a non-positive cap, price or limit, a request limit below the plan, prompt hashes that differ from the code, a labels path outside `.build`, and a set that differs from the manifest.

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

## Human adjudication (measured, October 9, 2026)

The user adjudicated all 50 items of set `jc-9adfaeeb572b8380` in one pass with the local form, applying the [category tolerances](#category-tolerances-user-decision-october-8-2026). The export's `adjudicator` field is blank; the adjudicator is the user. The export is private at `.build/judge-calibration/adjudications-jc-9adfaeeb572b8380.json` (SHA-256 `503e814290e5ee1f64567cc053280a3b7ea67c377e016cbe174da1fbd11f35ce`); the score report is `.build/judge-calibration/score-human-v1-20261009.json` (SHA-256 `51ff25b3e41a0fabbb43dcc14eec16a5dbb5e7d4404d19fe7d2faf7c4e75fed4`). Free-text notes stay private.

The same day the user settled the verdict rubric and added the faithful field, and a revised file applies those decisions; see [Revision of October 9, 2026](#revision-of-october-9-2026). **The revised file is the current reference.** The totals and the sufficiency comparison immediately below are the first export's, kept as recorded.

### Totals (first export)

| Measure | Count |
|---|---:|
| Accepted | 43 |
| Rejected | 7 |
| Pack sufficient / insufficient | 28 / 22 |
| Unsupported claims flagged | 0 |
| Sufficiency changed after reveal | 0 |

- **By answerer:** all 15 Sol answers accepted; Qwen 28 of 35. All seven rejects are Qwen answers: three temporal reasoning, two preference, two assistant recall.
- **Adjudication rules observed beyond the protocol:** an answer that first gives a wrong value and then corrects itself was rejected (2 items), and an answer that gives no answer or restates the question was rejected. The upstream judge prompt accepts a response that "contains" the correct answer, so upstream-prompt judges are expected to disagree with these two self-correction items.
- **Correct-plus-unsupported stratum:** both items were accepted without the unsupported flag, against their prior source-aware labels.

### Sufficiency against the annotation proxy (first export)

For the 37 answerable items, human sufficiency agrees with "every annotated positive turn delivered" on 33 (89 percent): 23 sufficient with all delivered, 10 insufficient without. Three were sufficient without every annotated turn and one insufficient with all of them. This supports R2's annotation proxy as a measure of sufficient evidence, on this sample. Eleven of 13 abstention items were marked insufficient, reading "insufficient" as "the evidence lacks the information"; abstention sufficiency labels therefore do not follow the protocol's definition and are excluded from sufficiency agreement.

In the first export, ten of the 11 answerable items with insufficient evidence had accepted answers, nine of them declines. The revision rejects those declines (below).

### Revision of October 9, 2026

User decisions of October 9, 2026: the answer verdict means agreement with the reference under the LongMemEval tolerances, so a decline on an answerable question is a reject even when the evidence lacked the answer (the sufficiency field captures that retrieval failure); and a new **faithful** field records whether the answer is honest about and consistent with the delivered evidence. The coordinator applied these decisions to the first export as a v2 revision, at `.build/judge-calibration/adjudications-jc-9adfaeeb572b8380-v2.json` (private; SHA-256 `7fb07112939eab8688f4559c853e5a511a0fde9f9362a4d03302dc96517140fb`). Its revision block names the first export's SHA-256 (`503e8142…5ce`), and `score --original-adjudications` verified it: the 13 listed items are exactly the difference between the two files (13 verdict changes, 1 sufficiency change, 10 faithful values), with no unlisted change.

Changed items (13):

- **Nine declines on answerable questions,** accept to reject, faithful yes: items 002, 012, 014, 015, 023, 025, 031, 038 and 040.
- **Items 006 and 047,** accept to reject: a wrong primary count with a hedge. Faithful not set.
- **Item 037,** accept to reject: a preference answer that is not personalized. Faithful not set.
- **Item 035,** sufficient to insufficient, and accept to reject, faithful yes.

| Measure (revised) | Count |
|---|---:|
| Accepted / rejected | 30 / 20 |
| Pack sufficient / insufficient | 27 / 23 |
| Faithful adjudicated | 10 (all `yes`); 40 not adjudicated |
| Unsupported claims flagged | 0 |
| Sufficiency changed after reveal (form) | 0 |

- **By answerer:** Qwen 16 accepted, 19 rejected; Sol 14 accepted, 1 rejected.
- **Rejects by category:** multi-session 6, assistant recall 5, temporal reasoning 4, preference 3, knowledge update 1, user recall 1. The 13 abstention items are all still accepted.
- **Faithful:** set only on the 10 revised items the user's instruction covers (9 Qwen, 1 Sol; 9 from the incomplete-evidence stratum, 1 from rejected), all `yes`, all rejects on insufficient packs. Faithful is not adjudicated on the other 40 items, so these are counts, not rates. Cross-tab of verdict, faithful and sufficiency: accept on sufficient packs 19 and on insufficient packs 11 (faithful not adjudicated); reject on sufficient packs 8 and on insufficient packs 2 (not adjudicated); reject, faithful yes, insufficient 10.
- **Sufficiency against the annotation proxy:** 34 of 37 answerable items agree (23 sufficient with all annotated turns delivered, 11 insufficient without); 2 sufficient without and 1 insufficient with.
- **Answers on answerable packs:** all 12 answerable items with insufficient packs are now rejected, and 10 of them are faithful declines or the revised item 035. On the 25 answerable items with sufficient packs, 17 answers are accepted and 8 rejected. Answer acceptance on its own still mixes retrieval and reading failures; A1 has to be measured on adjudicated sufficient packs, as the plan defines it.

### Earlier judges against the adjudication

These are the historical labels already attached to the items, from the runs that produced them, scored against the revised file. Each judge saw a different subset, so they are not a head-to-head comparison. All use the upstream reference-only prompt except where noted. No item carries the unsupported-claims flag, so the grounded and reference-only variants are identical. Counts are judge disagreements over adjudicated items; intervals are 95 percent Wilson intervals.

| Judge | Items compared | False reject (95% interval) | False accept (95% interval) | Error (95% interval) |
|---|---:|---|---|---|
| Qwen local, upstream QA prompt | 27 | 2/13, 15% (4-42%) | 0/14 (0-22%) | 2/27, 7% (2-23%) |
| JevK5 local, upstream QA prompt | 18 | 1/16, 6% (1-28%) | 0/2 (0-66%) | 1/18, 6% (1-26%) |
| Sol, upstream QA prompt | 13 | 0/12 (0-24%) | 0/1 (0-79%) | 0/13 (0-23%) |
| Qwen, four-field source-aware rubric | 2 | none adjudicated accept | 0/2 (0-66%) | 0/2 (0-66%) |
| Sol, four-field source-aware rubric | 2 | none adjudicated accept | 0/2 (0-66%) | 0/2 (0-66%) |
| Sol, source-only sufficiency | 8 | sufficiency agreement 8/8, kappa 1.0 | | |

- **Superseded first-export figures.** Against the first export, Qwen disagreed on 12 of 23 adjudicated accepts (52 percent, 33-71), JevK5 on 2 of 17 and Sol on 1 of 13. Eight of Qwen's 12 were the declines the revision now rejects, so most of that apparent false-reject rate was a rubric difference, not judge error. The earlier statement that Qwen rejects about half of correct answers, and that Qwen-judged accepted counts are therefore likely undercounts, does not hold against the revised reference.
- **Vertex Sonnet, first pass (candidate judge, not a historical label).** One replicate (labels SHA-256 `e2dfae7e…2c31`; 42 items with a parseable verdict, 29 with parseable sufficiency): false reject 1/26, 4% (1-19%); false accept 0/16 (0-19%); error 1/42, 2% (0-12%); sufficiency agreement 23/29 (kappa 0.59), abstention items included. This is one replicate of a three-replicate plan with 8 unparseable verdicts, so it is not a calibrated rate.
- **False accept is still weakly measured.** The revised set has 20 adjudicated rejects, but 10 of them are declines, which a reference-based judge rejects easily, and no earlier judge saw more than 14 of them (the Sonnet first pass saw 16). No judge has a single false accept, and every false-accept interval's upper bound is at least 19 percent. Separating judges on false accepts still needs plausible wrong answers; see the next steps below.

### Answer presentation defects

Seven accepted or rejected Qwen answers carry notes about visible metadata, envelope text such as "Original message text", stray dollar signs or poor prose. They come from the natural-v5, independent-v1, neighborhood-v1 and source-controls-v1 runs. This is a product defect separate from correctness. [ANSWER-PRESENTATION-DEFECTS.md](ANSWER-PRESENTATION-DEFECTS.md) gives the offline diagnosis. Four of the seven answers open with a copied recent-message envelope header. Across saved answers, the copy appears in 16 of 126 envelope answers and none outside the envelope. The cause is that prior assistant turns are sent framed with that header. Current `main` still renders the same envelope. The live echo rate on the current build is unmeasured.

### Next steps (proposed)

1. Extend the set with at least 25 likely-wrong answers (recent-only, insufficient-pack and earlier rejected attempts), adjudicated the same way, so false-accept intervals can separate judges.
2. Run the four built judge runners over the 50 items under filled declarations, after authorization.
3. Re-judge the Qwen-labelled records that inform current claims with the best-calibrated judge.

## What the user must do and authorize

To start P4 adjudication now (no model calls):

1. Decided October 8, 2026: apply the upstream LongMemEval tolerances (see [Category tolerances](#category-tolerances-user-decision-october-8-2026)). Still open: whether to adjudicate the two-item correct-plus-unsupported stratum as is or add reviewer-constructed items.
2. Open `.build/judge-calibration/set-v1-20261008/adjudication-form.html` locally, adjudicate the 50 items, and export the decisions into `.build/judge-calibration/`. A designated reviewer may do this instead; the export records the adjudicator name. Done October 9, 2026, then revised the same day.
3. Optional: record faithful on the 40 items where it is not adjudicated. The set's original form predates the field; regenerate the form with the `form` command (see [Adjudication format](#adjudication-format)), import the revised file, record faithful, and export. A new export carries no revision block, so keep the revised file as the record of the October 9 changes.

To run judges, each run needs its own authorization. The runners are built; none has run. For every judge: copy its template to `.build/judge-calibration/declarations/`, fill the fields in the table above, run the dry run, run `check-declaration` until it reports `"complete": true`, then authorize and run the execute command.

1. **Vertex Opus.** Use the version 2 template. Declare current Vertex AI prices for `claude-opus-5-5` with their source and date, a spending cap, and request limits of at least 300 generations and 100 counts. The cap must cover the reservation of counted input plus 2,048 output tokens per request (roughly $19 for 3 replicates at $4 and $20 per million; see the estimate above). Authorizing the run authorizes one unbilled access probe per session, the free counting pass of 100 count requests, and up to the declared number of billed generations.
2. **Vertex Sonnet.** The same with the version 2 template and prices for `claude-sonnet-5-5` (roughly $5 reserved for 3 replicates at $2 and $10 per million). Sonnet access was verified by the first pass. Use a new output directory and labels path; the first pass's run directory belongs to its version 1 declaration.
3. **JevK5 MCP.** Fill the mcpme executable SHA-256 (`shasum -a 256` of the command's first element) and a request limit of at least 300. Decide whether the 24,000-character estimate bound is acceptable, knowing it leaves at most 19 items with JevK5 sufficiency labels, or authorize a different bound. Authorizing the run authorizes starting the mcpme slot process and up to the declared number of local decisions.
4. **Qwen local.** Fill a request limit of at least 300, and make sure the selected Qwen model is the one loaded in mlx-serve on port 11234. Authorizing the run authorizes up to the declared number of local generation requests.
5. **Hosted Jev.** Out of the runner's scope. Move the key into the Keychain. Approve a plan amendment admitting the provider. Authorize the adapter, its contract and tests, and the data-terms review. Then authorize a declared, capped run.

After labels exist, `score` produces the rates. P4 step 3 then selects the judge or ensemble with the lowest error, and the earlier LongMemEval local labels are annotated with their judge's measured rates. Because the verdict prompt is reference-only, compare runner judges on the reference-only variant and report the grounded variant beside it.

### Unverified without a live call

- Under version 1, neither model reliably replies with a bare `yes`, `no` or JSON object: the first Sonnet pass left 21 of 100 replies unparseable. Version 2 is built to remove that failure, and none of the following has been exercised against the provider:
  - that Vertex accepts `output_config.format` with these schemas on both models and on the count endpoint (structured outputs are documented as available on Vertex AI and compatible with token counting);
  - that Sonnet accepts `thinking: {"type": "between_tools"}` with structured outputs and no effort field, and actually emits no thinking tokens with it;
  - that Opus accepts `output_config.effort: "low"` together with `format`, and how many thinking tokens it spends at low effort on the long sufficiency prompts, so whether 2,048 output tokens is enough;
  - whether the constrained verdict field changes verdicts compared with a bare reply to the same upstream prompt;
  - the input tokens the schemas add, and so the exact reservations.
- Opus access and model echo in `llm-train-482420` for these requests. Sonnet access, echo and the accepted omission of `temperature` were verified by the first pass.
- Token counts and therefore cost. Prices are not assumed anywhere in code.
- JevK5 token counts for long sufficiency requests, its behavior on requests near its context limit, and whether its cache makes replicates identical.
- That the running mlx-serve still serves the pinned Qwen model, and Qwen's adherence to the bare-JSON sufficiency reply.
- The real `StdioMCP`, `vertex.post` and loopback transports inside the runner. Their own synthetic contracts pass, and the runner was exercised only with fakes.

## Verification

- `python3 scripts/test_judge_calibration.py`: 21 synthetic contracts, all passing. They cover:
  - strata precedence;
  - seeded selection determinism and independence from input order;
  - selection unchanged when answer text or label details change;
  - quota, shortfall, per-question cap and fill counts, and removal of duplicate answers;
  - blinding of model identity, run, arm, prior labels, `_abs`, event, session and hex IDs, plus the leak detector;
  - private file modes, no-clobber output and the `.build` destination guard;
  - the form's network-free policy and script-injection escaping;
  - Wilson interval values, kappa and majority vote;
  - false-accept, false-reject, reference-only, replicate, sufficiency and self-preference scoring, and refusal of mismatched inputs;
  - sufficiency prompts that omit the answer, and verdict prompts from the upstream function;
  - both Vertex declaration templates and their checks;
  - native byte-range resolution with digest verification;
  - v1 and v2 adjudication loading, refusal of an invalid faithful value, of faithful or a revision block in a v1 file, and of an unknown format;
  - revision consistency against the original export: hash, unlisted changes (verdict, faithful, note text, reveal record), listed changes that did not happen, source and target mismatches, malformed, unknown and duplicate entries, and the CLI's fixed error code;
  - faithful counts, breakdowns and cross-tab, identical judge rates when only faithful changes, a revision's sufficiency change not counted as a change after reveal, and no note or rubric text in the score output;
  - the form's faithful field inside the post-reveal block, the decline rule text, v2 export, v1 and v2 import, and the `form` regeneration command (private modes, no overwrite, items hash check).
- `python3 scripts/test_judge_calibration_run.py`: 22 synthetic contracts with fake transports for all four judges, all passing. Five were added on October 9, 2026 for version 2: the reply schema hash pinned in code and templates and separate from the prompt hashes; request and count bodies per model (`thinking` and `output_config` fields, no sampling keys, version 1 bodies unchanged) and the dry run's reported fields; strict structured parsing with the fixed codes `output_off_schema`, `response_incomplete` (including a thinking-only truncated reply), `refusal` and `model_identity_mismatch`, receipts carrying stop reason and thinking tokens, and re-authentication of those captures; version 1 declarations keeping bare-text parsing and resume; and `check-declaration` refusing disabled or budgeted thinking, `between_tools` above effort `high` or on Opus, an implicit Opus effort, out-of-range output caps and a schema hash mismatch, with the adapter refusing the same combinations. The earlier 17 cover:
  - prompt hash pinning in code and in all four templates, and refusal of a changed prompt;
  - refusal of an upstream protocol file that does not match its pin;
  - blinding: with the key file deleted, no key-only string (run, arm, answerer model, question ID, prior judge names) and no item ID reaches any request, and sufficiency requests never contain the answer;
  - dry runs for all four judges with sockets, `vertex.post`, gcloud tokens, `StdioMCP`, the loopback client and every transport patched to fail: zero calls, nothing written;
  - the CLI gates: dry run without `--execute`, exit 2 with no transport constructed when the declaration is incomplete, and `--resume` refused without `--execute`;
  - the Vertex projected cost refusal before any generation, and the per-generation cap check;
  - stop on the first HTTP 429, a request limit reached on resume, and an authenticated resume that reuses completed requests and counts and re-sends only the failed one;
  - refusal of a resume with a tampered response capture or a different declaration;
  - parse failures recorded with empty labels, never coerced;
  - model identity mismatch halts for Qwen and Vertex, and the JevK5 executable pin halts before connecting;
  - replicate counts and order, labels accepted by `score` for JevK5, Qwen and Vertex, and JevK5 cache-hit counting;
  - local request limits, character bounds, private file modes, and reports free of item text;
  - local and Vertex declaration checks.
- `python3 scripts/test_vertex_anthropic.py`: 15 synthetic contracts, all passing, including Opus as the unchanged default, Sonnet selected per run with the same no-sampling contract and its own model-echo check, refusal of unsupported models before any connection, opt-in structured outputs and thinking controls validated per model with default bodies unchanged, and `response_metadata` reporting only the stop reason and thinking tokens while `parse_usage` keeps reasoning at zero. The adapter's existing callers (`evaluate_answerer_controls.py`, `run_memory_investigation.py`, `evaluate_orientation_zoom.py`) default to Opus and their synthetic suites pass unchanged. Runs that capture `vertex_anthropic.py` as a pinned dependency will record the new file hash.
- `python3 scripts/check.py` runs both calibration suites and the adapter suite.
- The form's reveal gate, change-after-reveal record, navigation, autosave and export format were exercised in a browser against a synthetic set, which was then deleted. The private set was not opened in a browser by this preparation.
- October 9, 2026: the faithful field was exercised in a browser against a new synthetic three-item set, then deleted: it appears only after the reveal, an item counts complete only with faithful, the progress line reports items that need faithful, the export is v2 with `faithful`, a v1 import arrives with faithful unset and re-exports as v2, an invalid imported faithful value becomes null, and an unknown format is refused. The form's Content-Security-Policy blocked a test `fetch`. A v2 export of that shape scores. The private form was regenerated for the real set into a worktree's `.build/` and checked structurally (50 items, set ID and items hash, no unreplaced placeholder), not opened in a browser.
