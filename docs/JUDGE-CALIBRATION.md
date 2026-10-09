# Judge calibration (P4) preparation

Prepared October 8, 2026 for work package P4 of the [design repair plan](DESIGN-REPAIR-PLAN.md#p4-judge-calibration). This record separates three kinds of statement:

- **Implemented:** `scripts/judge_calibration.py` (inventory, blinded assembly, local adjudication form with the faithful field, form regeneration, v1 and v2 adjudication loading with revision checks, scoring, declaration check, frozen judge prompts, Vertex reply schemas; since October 9, 2026 also prompt set v4, the likely-wrong extension assembly with replay candidates and the self-correction heuristic, and the `subset` command; also the derived reference file (`derive-reference`), `pool-scores`, the `merge-regrade` helper for a re-graded subset (built, not used), and, kept for history only, the [combined rule](#reference-target-files-and-the-withdrawn-evidence-relative-target-implemented-october-9-2026) with a lexical decline classifier (`score --combined-rule`)), `scripts/test_judge_calibration.py` (29 synthetic contracts), the [judge runner](#judge-runner-implemented-not-run) `scripts/judge_calibration_run.py` with `scripts/test_judge_calibration_run.py` (31 synthetic contracts), `scripts/vertex_anthropic.py` parameterized by model with opt-in structured outputs and thinking controls (15 synthetic contracts), and nine declaration templates under `scripts/judge_calibration_declarations/` (version 4 for Sonnet, version 3 and version 2 for the two Vertex judges, version 1 kept for runs made under it, and the two local judges).
- **Measured:** the inventory counts below, the composition of the assembled set, and the runner's dry-run counts over that set. They are metadata counts. Since October 9, 2026 also: the user's [human adjudication](#human-adjudication-measured-october-9-2026) of all 50 items, its [revision](#revision-of-october-9-2026), the earlier judges' error rates against the revised file, one live version 1 Vertex Sonnet pass, the [version 3 Sonnet run](#vertex-sonnet-declaration-version-3-measured-october-9-2026) that became the default judge, the [prompt set v4 candidate run](#vertex-sonnet-prompt-set-v4-candidate-measured-october-9-2026), the composition of the [likely-wrong extension set](#likely-wrong-extension-set-assembled-and-adjudicated-october-9-2026), its human adjudication, the [final reference adjudication of the extension](#decline-rule-reversal-user-decision-october-9-2026-latest), and the [default judge and prompt set v4 on all 79 items](#prompt-sets-v3-and-v4-on-79-items-measured-october-9-2026), rescored offline against the final reference target. Kept as history: the v3 adjudication of the 50 items under the withdrawn [decline-rule change](#decline-rule-change-user-decision-october-9-2026-later-the-same-day), and the scores against the withdrawn evidence-relative target.
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
   - *Reject:* any of those conditions fails. A self-correction or self-contradiction is a reject even when the correct value appears; see [Self-corrections](#self-corrections-user-decision-october-9-2026).
   - *Declines (user decision of October 9, 2026, latest):* a decline ("no record of that") on an answerable question is a reject, whether or not the delivered evidence contained the answer. An honest decline is reported through faithful and pack sufficiency, not through the verdict. See [Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest). An intermediate rule of the same day was withdrawn. Under it, an honest decline on evidence that lacked the answer was an accept ([history](#decline-rule-change-user-decision-october-9-2026-later-the-same-day)).
   - *Unsure:* the item is excluded from rate denominators and counted separately.
6. If the only reason for a reject is an unsupported claim in an answer that agrees with the reference, also tick **unsupported claims**. This lets scoring compute a reference-only variant.
7. Record **faithful to the evidence**: whether the answer is honest about and consistent with the delivered evidence, independent of the reference.
   - *Yes:* for example an honest decline on insufficient evidence, or an honest undercount that reports what the evidence shows. On an answerable question both are faithful rejects.
   - *No:* the answer contradicts the evidence, or claims something the evidence does not show.
   - *Unsure:* use sparingly.

   Faithful is recorded after the reveal, next to the verdict. It is reported by `score` but never enters judge error rates: judges are calibrated on the verdict only. A decision without it (`null`) means not adjudicated.
8. Add an optional note, export decisions, and save the export under `.build/judge-calibration/`.

Decisions autosave in browser local storage when it is available. Export regularly; "Clear saved progress" removes the browser copy. Notes can contain private text, so exports are private files. The form counts an item complete only when sufficiency, verdict and faithful are all recorded, and reports items that still need faithful. It imports v1 and v2 exports (a v1 decision imports with faithful unset) and always exports v2. An imported revision block is not carried into a new export.

### Adjudication format

Exports and revisions are JSON files with `format`, `set_id`, `items_sha256`, `adjudicator`, `exported_at` and `decisions` (item ID to decision). A decision holds `sufficiency`, `verdict`, `unsupported_claims`, `note`, `sufficiency_at_reveal` and `revealed`.

- **`boros-judge-calibration-adjudications-v1`:** the first form's export. It has no `faithful` key; a v1 file that carries one, or a `revision` block, is refused (`adjudication_faithful_requires_v2`, `adjudication_revision_requires_v2`).
- **`boros-judge-calibration-adjudications-v2`:** adds `faithful` per decision, one of `yes`, `no`, `unsure` or `null` (`adjudication_faithful_invalid` otherwise). The current form exports this format.
- **Revision block (v2 only, optional):** a revised file applying later rubric decisions carries `revision` with `of_export_sha256` (the SHA-256 of the export it revises), `revised_on` (`YYYY-MM-DD`), `authorized_by`, `applied_by`, `rubric`, optional `faithful_coverage`, and a non-empty `changes` list. Each change names an `item`, an optional `reason`, and one or more changed fields among `sufficiency`, `verdict`, `faithful`, `unsupported_claims` and `note`, written `"from->to"` (`null`, `true` and `false` as words), a bare `"to"` for a field the original did not carry (faithful in a v1 original), or `"changed"` for a note. A revision block may also carry descriptive keys that `score` does not check. The extension's final reference file carries `classification` and `supersedes_reference_file_sha256`, and `merge-regrade` writes `regrade`.

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

### Self-corrections (user decision, October 9, 2026)

The user decided in chat on October 9, 2026 that **self-corrections are rejected**. An answer that first states a wrong answer and then corrects itself, or that contradicts itself (for example, a wrong headline followed by reasoning that reaches the reference), is a reject even if the correct value appears in it. The rule applies to every category, abstention included.

- **Scope.** The rule is about the answer contradicting itself. It does not change the knowledge-update tolerance: an answer that reports earlier, superseded information as earlier and gives the updated value as its answer does not contradict itself. Nor does it change the temporal off-by-one tolerance, which decides whether a value counts as wrong at all.
- **Where it differs from upstream.** The upstream LongMemEval prompt accepts a response that "contains" the correct answer. Judges that use that prompt unchanged therefore tend to accept self-corrections. That covers the default judge (prompt set v3), the Qwen and JevK5 graders and the Sol upstream labels. Prompt set v4 adds one sentence for this rule; see [Prompt set v4](#prompt-set-v4-self-correction-rubric-implemented-october-9-2026).
- **Consistency of the revised adjudication.** Checked October 9, 2026 by reading the 50 items locally. The revised (v2) file already applies the rule, so no item changes and no new adjudication file was produced for it. The two self-corrections, item-010 and item-011, are rejects. None of the 30 accepted items is a self-correction. The nearest case is item-003, an abstention item: it reports team sizes for a different role than the one asked about, then says the asked-about role is not in the records. It never states a count for the asked-about role, so it does not contradict itself.

### Decline-rule reversal (user decision, October 9, 2026, latest)

The user decided in chat, in the latest decision of October 9, 2026, to **reverse the [decline-rule change](#decline-rule-change-user-decision-october-9-2026-later-the-same-day)** made earlier the same day. The verdict means agreement with the reference under the LongMemEval [category tolerances](#category-tolerances-user-decision-october-8-2026), as in the [revision of October 9, 2026](#revision-of-october-9-2026). A decline on an answerable question is a reject. Honest declines are reported through the faithful field together with pack sufficiency, not through the verdict. The [self-correction rule](#self-corrections-user-decision-october-9-2026) (reject) stands.

Reasons recorded with the decision:

1. **A2 is an end-to-end measure.** It must not rise when retrieval fails politely. Each failure has its own measure:
   - retrieval failure: R2 and the sufficiency field;
   - honesty: the faithful field;
   - the reader: A1 on sufficient packs.
2. **The reference-only verdict prompt cannot grade evidence-relative correctness.** Against the evidence-relative target, the judge alone had 43 to 44 percent error, and the combined rule 24 to 25 percent ([history](#prompt-sets-v3-and-v4-on-79-items-measured-october-9-2026)).

**Reference adjudications now in force.**

| Set | Reference adjudication (private, `.build/judge-calibration/`) | SHA-256 | Accepted / rejected |
|---|---|---|---:|
| 50 items `jc-9adfaeeb572b8380` | `adjudications-jc-9adfaeeb572b8380-v2.json`, the [revision of October 9, 2026](#revision-of-october-9-2026), again | `7fb07112…40fb` | 30 / 20 |
| 29-item extension `jx-6dbd69dec7456178` | `adjudications-jx-6dbd69dec7456178-reference-v2.json`, below | `9505afbe4db18ed1a9ddecbb4d5407335e974369420d8437ff046a58e3bc57a7` | 5 / 24 |

Superseded files, kept and not deleted:

- `adjudications-jc-9adfaeeb572b8380-v3.json` (`94c751a5…8510`), the 50 items under the withdrawn rule;
- `adjudications-jx-6dbd69dec7456178-reference-derived.json` (`8667fc4b…3f50`), the extension's first reference file, with only the 14 declines flipped.

The user's extension export (`1b2d7abe…75e9`) is kept unchanged as the record of the user's own decisions.

**Final reference adjudication of the extension.** The user decided in chat not to re-grade the 8 non-decline accepts on insufficient packs in the form ("just flip the answers i chose if we already know what happened"). The coordinator read those 8 answers locally against their references, at the user's instruction, and classified them under reference agreement:

- **Six flipped from accept to reject.** The coordinator's reasons, by category only:
  - item-003: a decline with guessed values that disagree with the reference;
  - item-005: a preference answer not tailored as the reference expects (the item-037 precedent);
  - item-013: a generic preference answer (the item-037 precedent);
  - item-014: a wrong count;
  - item-019: a partial fact followed by a decline on an answerable question (the lexical classifier missed this decline);
  - item-025: a decline with suggested sources that disagree with the reference.
- **Two kept as accepts:**
  - item-023 agrees with the reference;
  - item-007's top suggestion agrees with the reference. Its metadata leak is a [presentation defect](ANSWER-PRESENTATION-DEFECTS.md), not a verdict issue.

The file is a v2 revision of the user's export. It differs from the user's export in 20 verdicts, all accept to reject:

- the 14 accepted declines of the derived file: items 001, 002, 006, 011, 015, 016, 018, 020, 021, 024, 026, 027, 028 and 029;
- the 6 items above.

Sufficiency, faithful, notes and the reveal record are unchanged. The revision block names:

- the export's SHA-256;
- the rule;
- each change with its reason;
- that the 6 flips and the 2 kept accepts were classified by the coordinator at the user's instruction;
- the superseded derived file's hash.

`score --original-adjudications` with the user's export verified that the 20 listed verdict changes are exactly the difference between the two files.

| Measure (extension, final reference) | Count |
|---|---:|
| Accepted / rejected | 5 / 24 |
| Pack sufficient / insufficient | 6 / 23 (unchanged) |
| Faithful yes / no | 28 / 1 (unchanged) |
| Verdict / faithful / sufficiency | accept, yes, insufficient 2 (items 007 and 023); accept, yes, sufficient 3; reject, yes, insufficient 20; reject, yes, sufficient 3; reject, no, insufficient 1 (item-013) |

Faithful rejects on insufficient packs: 20 of the 23 insufficient packs. These are the declines and undercounts that the faithful field reports and that the verdict no longer counts as correct.

**Re-grade subset (built, not used).** Before the user's decision, subset `js-d6e4fafd1df7aa90` was built at `.build/judge-calibration/set-x1r-20261009/` in the coordinator worktree, with a form. It holds the 8 items under new opaque IDs, and its key maps them back to the extension's items through `source_item_id`. Nothing was exported from it, and it did not contribute to the final file. The `merge-regrade` helper ([below](#merging-a-re-graded-subset-merge-regrade-implemented-not-used)) would apply such an export if a re-grade is ever wanted.

**Items 024 and 029 (checked by the coordinator, October 9, 2026).** Both prompt sets accept them; the final file keeps both as rejects. The coordinator read both answers against their references, and both are judgment calls under the existing rules, not clear accepts. Item-024 declines, then lists three candidate sites, one of which is the reference. It never identifies which site it was, so it is a hedged guess, rejected like the hedged counts 006 and 047. Item-029 first says the history has no information about the setup, then cites an excerpt that does and gives suggestions matching the reference. That is a self-contradiction, rejected under the self-correction rule. The user can overturn either.

### Decline-rule change (user decision, October 9, 2026, later the same day)

**Withdrawn.** The user reversed this rule in the latest decision of October 9, 2026; see [Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest). This section is kept as history.

The user decided in chat, later on October 9, 2026, that **an honest decline on an answerable question is an accept when the delivered evidence does not contain the answer**. Under that rule the verdict meant "right given the delivered evidence". It superseded the decline part of the [revision of October 9, 2026](#revision-of-october-9-2026), which made every such decline a reject. Unchanged under it:

- the [self-correction rule](#self-corrections-user-decision-october-9-2026): a wrong answer followed by a correction is a reject;
- a preference answer that is not personalized when personalization was possible is a reject (item-037);
- a wrong count with a hedge is a reject (items 006 and 047).

**Adjudication v3 of the 50 items (applied October 9, 2026; superseded, kept).** Private file `.build/judge-calibration/adjudications-jc-9adfaeeb572b8380-v3.json`, SHA-256 `94c751a5ad021b3bc7aa5baed0a790f86e4140c042dc1464f54e7c579e148510`. Its revision block names the v2 file's SHA-256 (`7fb07112…40fb`), the rule, and each change. `score --original-adjudications` with the v2 file verified that the 10 listed items are exactly the difference between the two files: 10 verdict changes and no change to any other field.

- **Nine declines, reject to accept:** items 002, 012, 014, 015, 023, 025, 031, 038 and 040. Faithful `yes` and sufficiency `insufficient` are kept.
- **item-035, reject to accept, listed separately for the user's review** (`for_user_review` in the revision block). The user accepted it in the first export. It is not a decline. It reports what the delivered evidence shows, which is less than the reference. Under "right given the delivered evidence" its verdict reverted to accept; sufficiency stayed `insufficient` and faithful stayed `yes`. With the reversal, the v2 file's reject is again the reference verdict, so the question is moot.
- **Not changed:** the rejects 006, 047 and 037, the self-corrections 010 and 011, and every other decision.

| Measure (v3) | Count |
|---|---:|
| Accepted / rejected | 40 / 10 |
| Pack sufficient / insufficient | 27 / 23 |
| Faithful adjudicated | 10 (all `yes`, all accepted on insufficient packs); 40 not adjudicated |
| Verdict / faithful / sufficiency | accept, not adjudicated, sufficient 19; accept, not adjudicated, insufficient 11; accept, yes, insufficient 10; reject, not adjudicated, sufficient 8; reject, not adjudicated, insufficient 2 |

The ten rejects are items 001, 006, 007, 009, 010, 011, 019, 037, 039 and 047. The v2 file is again the 50-item reference adjudication, and v3 is superseded.

## Scoring (implemented)

```sh
python3 scripts/judge_calibration.py score --set .build/judge-calibration/set-v1-20261008 \
  --adjudications .build/judge-calibration/adjudications-jc-9adfaeeb572b8380-v2.json \
  --original-adjudications .build/judge-calibration/adjudications-jc-9adfaeeb572b8380.json \
  --labels vertex-opus=.build/judge-calibration/labels-vertex-opus.json
```

Score inputs:

- **Adjudications:** a v1 or v2 export, or a v2 revision (see [Adjudication format](#adjudication-format)). The set ID and the items hash must match. Judge rates are against this file as recorded. The verdict target is agreement with the reference ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)), so pass a reference adjudication: the 50-item v2 file or the extension's `-reference-v2` file.
- **Original adjudications (optional):** the export a revision names, or the source of a [derived reference file](#reference-target-files-and-the-withdrawn-evidence-relative-target-implemented-october-9-2026); `score` then verifies the revision or the derivation against it.
- **Combined rule (optional, history only):** `--combined-rule lexical` or `--combined-rule lexical-with-partial`. It was built for the withdrawn evidence-relative target and is not a current grader; see [the combined rule](#reference-target-files-and-the-withdrawn-evidence-relative-target-implemented-october-9-2026).
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
- **Disagreements (since October 9, 2026):** each variant lists the item IDs of its false accepts and false rejects. Each candidate column with labels carries the labels file's SHA-256, and the adjudication summary carries the adjudication file's SHA-256 and, for a derived file, its derivation summary.

At 50 items, a rate near 50 percent has a Wilson half-width of about 13 to 14 points. Per-category cells hold 4 to 13 items, so per-category intervals will be wide. Report them, but do not treat them as decisive.

## Reference target files and the withdrawn evidence-relative target (implemented October 9, 2026)

The verdict target is agreement with the reference ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)). The verdict prompts of prompt sets v2, v3 and v4 are reference-only: the judge sees the question, the reference and the answer, never the evidence. That matches the target.

**History.** For a few hours on October 9, 2026, the [decline-rule change](#decline-rule-change-user-decision-october-9-2026-later-the-same-day) made the human verdict mean "right given the delivered evidence". Scoring then used two targets. The evidence-relative target is withdrawn. The table and its scores are kept as history only.

| Target | Meaning | 50-item set `jc-9adfaeeb572b8380` | 29-item extension `jx-6dbd69dec7456178` |
|---|---|---|---|
| Evidence-relative (withdrawn) | The user's labels under the withdrawn rule: right given the delivered evidence | Adjudication v3 (`94c751a5…8510`), superseded | The user's export (`1b2d7abe…75e9`), unchanged |
| Reference, first version (superseded for the extension) | The evidence-relative target, except that an accepted decline on an answerable question is a reject | Adjudication v2 (`7fb07112…40fb`), still the 50-item reference | Derived file `adjudications-jx-6dbd69dec7456178-reference-derived.json` (`8667fc4b…3f50`): 14 accepted declines flipped to reject |
| Reference, final (current) | Agreement with the reference | Adjudication v2 (`7fb07112…40fb`) | `adjudications-jx-6dbd69dec7456178-reference-v2.json` (`9505afbe…57a7`): the 14 declines plus 6 classified non-decline answers flipped to reject ([details](#decline-rule-reversal-user-decision-october-9-2026-latest)) |

- **v2 and v3 of the 50 items differ in one non-decline item, item-035.** v2 and v3 differ in the nine declines and in item-035. item-035 reports what an insufficient pack shows, which is less than the reference, so it is wrong against the reference. A purely mechanical flip of declines would have left it accepted.
- **The first extension reference file flipped declines only.** It flipped the 14 accepted declines on answerable questions that the coordinator verified by reading: 001, 002, 006, 011, 015, 016, 018, 020, 021, 024, 026, 027, 028 and 029. It left as accepts the 8 non-decline answers the user had accepted on insufficient packs (003, 005, 007, 013, 014, 019, 023 and 025). The final file resolves those 8: 6 are rejects and 2 stay accepts.
- **Two flipped declines are accepted by both judges.** Both prompt sets accept items 024 and 029, which makes them false accepts against the reference target. Item-024 is a partial decline (its decline phrase starts after 200 characters), and item-029 is a preference answer. Whether either answer also contains the reference, which would make the flip wrong, has not been checked.

**Derived files (`derive-reference`).** The command reads a v2 adjudication and a list of accepted declines, and writes a fresh private file. In that file each listed item has verdict `reject`, and a `derived` block records:

- `target` `reference`;
- `of_export_sha256`, the source file's hash;
- `derived_on`, `applied_by` and `rule`;
- one change per item, `verdict` `accept->reject`.

The source's own revision block is not copied; the source keeps it. On every load, `score` checks the block: a known, non-abstention item, listed once, whose verdict is now `reject`. A file with both `derived` and `revision` is refused. With `--original-adjudications SOURCE`, `score` also requires the source hash and requires the listed flips to be the only difference, with every other decision field identical. Fixed codes: `adjudication_derived_invalid`, `adjudication_derived_change_invalid`, `adjudication_derived_unknown_item`, `adjudication_derived_duplicate_item`, `adjudication_derived_target_mismatch`, `adjudication_derived_item_abstention`, `adjudication_derived_with_revision`, `adjudication_derived_source_hash`, `adjudication_derived_source_invalid`, `adjudication_derived_source_mismatch` and `adjudication_derived_unlisted_change`.

```sh
python3 scripts/judge_calibration.py derive-reference --set .build/judge-calibration/set-x1-20261009 \
  --adjudications .build/judge-calibration/adjudications-jx-6dbd69dec7456178.json \
  --decline item-001 --decline item-002 ... --decline item-029 \
  --applied-by "..." --derived-on 2026-10-09 \
  --output .build/judge-calibration/adjudications-jx-6dbd69dec7456178-reference-derived.json
python3 scripts/judge_calibration.py score --set .build/judge-calibration/set-x1-20261009 \
  --adjudications .build/judge-calibration/adjudications-jx-6dbd69dec7456178-reference-derived.json \
  --original-adjudications .build/judge-calibration/adjudications-jx-6dbd69dec7456178.json \
  --labels vertex-sonnet=.build/judge-calibration/labels-vertex-sonnet-v3-x1-r3.json --no-prior
```

### Merging a re-graded subset (`merge-regrade`, implemented, not used)

The command applies a re-graded subset's form export to the source set's reference adjudication, and writes a new versioned file. The subset is one made with `subset` from items of the source set.

- **Mapping.** Subset item IDs map to source item IDs through the subset key's `source_item_id`.
- **Checks before anything is written:**
  - the subset key names the source set's ID and items hash;
  - every subset item equals its source item apart from its ID;
  - the export is a v2 form export (no revision or derived block) whose set ID and items hash match the subset manifest;
  - the export decides every subset item with sufficiency, verdict and faithful.
- **What is applied.** Only verdict, sufficiency, faithful and a non-empty note come from the re-grade. An empty re-grade note keeps the earlier note. The reveal record and the unsupported-claims flag stay as they were.
- **The new file.** The base file's own `revision` or `derived` block is not copied; the base keeps it. A new `revision` block names:
  - the base file's hash;
  - the date, the authorizer, the applier and the rubric (by default the reference-agreement rubric);
  - one change per changed item, each with the subset item it came from;
  - a `regrade` record with the subset's set ID, items hash, key hash, the export's hash and the item map.

  `score --original-adjudications BASE` verifies the result.
- **Refusals.** A re-grade that changes nothing is refused (`regrade_no_change`). Other fixed codes: `regrade_subset_key_invalid`, `regrade_source_set_mismatch`, `regrade_unknown_item`, `regrade_duplicate_source_item`, `regrade_item_mismatch`, `regrade_export_invalid`, `regrade_items_mismatch`, `regrade_incomplete` and `regrade_base_requires_v2`. The command prints IDs, labels and hashes only, and refuses an existing destination.

It was built for the 8-item re-grade, which the user then decided against, so it has not been run on private data. If a re-grade is ever exported from subset `js-d6e4fafd1df7aa90`:

```sh
python3 scripts/judge_calibration.py merge-regrade --set .build/judge-calibration/set-x1-20261009 \
  --adjudications .build/judge-calibration/adjudications-jx-6dbd69dec7456178-reference-v2.json \
  --subset .build/judge-calibration/set-x1r-20261009 \
  --regrade .build/judge-calibration/adjudications-js-d6e4fafd1df7aa90.json \
  --authorized-by "..." --applied-by "..." --revised-on YYYY-MM-DD \
  --output .build/judge-calibration/adjudications-jx-6dbd69dec7456178-reference-v3.json
```

**Combined rule (`score --combined-rule`, history only).** This rule was built to grade the now withdrawn evidence-relative target by machine, from a reference-only judge plus metadata (`boros-judge-calibration-combined-rule-v1`). It is kept so that the recorded figures can be reproduced. It is not a current grader, and the code marks it as superseded.

> accept = the judge accepts, OR (the answer is a decline AND the annotated gold turns of an answerable question were not all delivered whole); otherwise the judge's verdict.

- **Gold delivery** is the key's `all_annotated_delivered`, from dataset annotations and delivery metadata, with no judge. Abstention questions have no gold turns, so the rule leaves them to the judge.
- **Decline detection** is the lexical classifier `boros-judge-calibration-lexical-decline-v1`: the rule of `answer_presentation_replay.decline_outcome`, with the 24 plain-decline phrases in `answer_presentation_defects.PLAIN_DECLINES`. It reports `decline` when a phrase starts within the first 200 characters, and `partial_decline` when a phrase appears only later. A test checks that it equals the replay function.
- **Modes.** `lexical` counts `decline` only. `lexical-with-partial` also counts `partial_decline`.
- **Output.** The rule is scored as the variant `combined` against the supplied adjudication as recorded. The report's `combined_rule` block lists, by ID only, the lexical declines, the partial declines, the gold-not-whole items and the items the rule accepts.

**Pooling (`pool-scores`).** Sums the overall counts of score reports from different sets, per candidate judge and variant, and recomputes rates and Wilson intervals. It reports disagreements as `set_id:item_id` and refuses a duplicate set or a variant missing from one report.

### Lexical decline classifier against the user's labels (measured October 9, 2026)

Truth: the accepted declines on answerable questions that the user's labels identify. These are the nine v2-to-v3 items and the 14 extension items, 23 of the 66 answerable items. All 13 abstention items are accepted declines or "not available" answers. No classifier hit falls outside the known declines. A decline the user rejected, for example one given when the answer was delivered, would not appear in this truth set. None was found.

| Mode | True positive | False negative | False positive | True negative | Recall (95% interval) |
|---|---:|---:|---:|---:|---|
| `lexical` (opening decline) | 16 | 7 | 0 | 43 | 16/23, 70% (49-84%) |
| `lexical-with-partial` | 17 | 6 | 0 | 43 | 17/23, 74% (54-87%) |
| Abstention items (not used by the rule) | 0 | 13 | | | 0/13 (0-23%) |

- **Missed declines.** In the 50-item set: 002, 015 and 023. In the extension: 011, 020 and 027, plus 024, which `lexical-with-partial` catches. Precision is 16 of 16 (no false positive among 43 answerable non-declines, 0-8%).
- **Assessment.** The classifier is not reliable enough to decide accepts. It misses about a third of the declines, its recall interval reaches down to 49 percent, and it finds none of the 13 abstention declines. That last miss shows that the phrase list covers only some decline wordings. Widening the list after reading these 79 items would fit it to them.
- **The rule's ceiling.** Even with the user's own decline list in place of the classifier (an analysis, not a mode), the combined rule leaves 11 (v3) or 14 (v4) false rejects among the 65 evidence-relative accepts. The reason is that "right given the delivered evidence" also accepts non-decline answers that are consistent with an insufficient pack (jc-035 and jx-003, 005, 007, 013, 014, 019 and 025). A reference-only judge rejects those by design. jc-023 is also out of reach: it is a decline the user accepted on a pack whose annotated turns were all delivered.
- **A further miss.** Under the final reference classification, extension item-019 is also a decline (a partial fact, then a decline). The truth set above predates that reading and counts it as a non-decline.
- **Alternatives considered (not implemented):**
  1. **Withdrawn: an evidence-aware verdict task.** In it the judge would see the delivered evidence, as the superseded prompt set v1 proposed, so that it could grade the evidence-relative target. That target is withdrawn ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)), so this proposal is withdrawn with it.
  2. **Not proposed for now: a decline-classification judge task.** Question and answer only, yes or no to "does the answer say the information is not available instead of answering?". It no longer bears on the verdict. It could one day count declines for A2 reports, next to the faithful field, if hand counts become impractical. It would need its own prompt, calibration and authorization.

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

### Vertex reply schemas (implemented October 9, 2026; blocked by organization policy)

Version 2 Vertex declarations constrain both replies with structured outputs: the request field `output_config.format` of type `json_schema`. The deprecated `output_format` field is never sent. The schemas are a transport constraint, defined in `REPLY_SCHEMAS` in `scripts/judge_calibration.py` (version `boros-judge-calibration-reply-schemas-v1`), and are separate from the prompts: the prompt texts and the three prompt hashes above are unchanged.

| Stage | Schema | Label mapping |
|---|---|---|
| Verdict | An object with one required string field `answer`, enum `yes` or `no`, `additionalProperties: false` | `yes` to accept, `no` to reject |
| Sufficiency | An object with one required string field `sufficiency`, enum `sufficient` or `insufficient`, `additionalProperties: false`; exactly the object the sufficiency prompt asks for | unchanged |

Reply schema set SHA-256: `089f6abbd4ee62321396ed07e5929cfe30394cfe04f6c44e9512f60bc3fca549`. Version 2 declarations pin it in a `reply_schemas` block, `check-declaration` refuses a mismatch (`reply_schema_hash`), and the run record, the labels file, the dry run and every session report carry it.

The upstream verdict prompt still asks for a bare yes or no; the schema wraps that answer in one JSON field. Whether this changes Sonnet's or Opus's verdicts relative to a bare reply is unmeasured. Parsing of constrained replies stays strict: surrounding whitespace is allowed, and anything else (another key, another value, a duplicate key, a code fence, prose) is the recorded failure `output_off_schema`, never coerced. Version 1 declarations keep the bare-text parsing described above.

### Structured outputs blocked by organization policy (measured October 9, 2026)

Version 2 cannot run in `llm-train-482420`. Synthetic probes on October 9, 2026 against `claude-sonnet-5-5` (no calibration data) found:

- A plain request succeeds, and so does a request with `thinking: {"type": "between_tools"}`.
- A generation request carrying `output_config.format` fails with HTTP 400 `FAILED_PRECONDITION`: the organization policy `constraints/vertexai.allowedPartnerModelFeatures` (effective policy `denyAll`) blocks the partner-model feature `structured_outputs`. The count endpoint accepts the same field, so the free counting pass does not reveal the block.
- Changing the policy needs an organization administrator; the user cannot change it, and nothing in this repository changes it.

The version 2 Sonnet run (`runs/vertex-sonnet-v2-r3/` in the coordinator worktree) halted on its first generation for this reason. Metadata only: the access probe reported `reachable`; 96 count requests completed; 1 generation request failed with `http_status_400` and the session stopped (`halt_reason` `http_status_400`); 299 of 300 planned requests were not attempted; no label was produced; observed cost $0 (reserved $0.020858 against an $8 cap). The run stays valid and resumable under its version 2 declaration (its run record matches the current code and its captures re-authenticate, checked read-only), but resuming it would fail the same way while the policy stands.

### Vertex instructed JSON replies (version 3, implemented October 9, 2026, not run)

Approved by the user on October 9, 2026 as the fallback while structured outputs are blocked. Version 3 Vertex declarations (format `boros-judge-calibration-vertex-declaration-v3`) send no `output_config.format`. Instead, each request carries one fixed system line that asks for the same JSON shape as the version 2 schemas:

| Stage | System line (exact text) |
|---|---|
| Verdict | `Reply with only a JSON object, either {"answer": "yes"} or {"answer": "no"}, and no other text.` |
| Sufficiency | `Reply with only a JSON object, either {"sufficiency": "sufficient"} or {"sufficiency": "insufficient"}, and no other text.` |

- **Placement.** The line is a separate system message, after the stage's own system text if any and before the user message. The adapter joins system messages with a blank line, so the verdict request's `system` field is the line alone, and the sufficiency request's `system` is the unchanged sufficiency system text, a blank line, then the line. The user messages, the upstream verdict prompt and the sufficiency prompt are byte-identical to version 2. The lines specify format only; they carry no grading guidance. The sufficiency system text already asks for the same object, so its line repeats an existing instruction.
- **Prompt set v3.** `REPLY_INSTRUCTIONS` in `scripts/judge_calibration.py` (version `boros-judge-calibration-reply-instructions-v1`, SHA-256 `8ecc9d7d83ede598616631604f3ef92f89c609c507a59c5ea9f1c2097252cbcb`) holds both lines, their placement, the accepted shapes (the version 2 schema objects, used only by the parser) and the parse rule. `JUDGE_PROMPTS_V3` (version `boros-judge-calibration-prompts-v3`, SHA-256 `b6bcccc27ac4d16fc9d5cb550d3201c3f56f44a251190087af740180fafd317c`) is the unchanged verdict and sufficiency definitions plus `REPLY_INSTRUCTIONS`. The component hashes are unchanged: verdict `85fa445a…c40c`, sufficiency `c6044858…b857`, upstream `ecce9c4c…5251`, and the version 2 prompt set `1cce1566…0221`. A version 3 declaration pins all of them plus `reply_instructions_sha256`.
- **Parsing (strict).** Exactly one JSON object with exactly the shape's single field and one of its enum values; duplicate keys are refused. Tolerated around it: surrounding whitespace, and one surrounding Markdown code fence (an opening line of three backticks, optionally followed by `json`, and a closing line of three backticks). The fence tolerance is declared in the `reply_format` block (`parse_tolerance`) and in the hashed parse rule. Anything else, including prose before or after the object, a second object, another key, another value or another fence language, is `output_off_schema` (status `parse_failed`). A reply stopped by `max_tokens` is `response_incomplete` and a refusal is `refusal` (status `response_invalid`). Prose is never coerced to a label. Each completed receipt records `reply_wrapper` (`bare` or `fenced`), and each session report counts them in `replies_session.wrappers`.
- **Requests.** Sonnet: `thinking: {"type": "between_tools"}`, provider-default effort (not sent), 512 output tokens. Opus: `output_config: {"effort": "low"}` without `format`, no `thinking` field, 2,048 output tokens. Count bodies carry the same `system` and `messages`, and no `output_config`.
- **Comparability caveat.** Version 3 labels come from prompt set v3, not from the prompt set v2 that the upstream-only judges (Qwen local, JevK5) and the earlier records use. The added line is format-only, but the verdict judge sees one system line that the upstream protocol does not have, and the effect of that line on verdicts is unmeasured. Report version 3 Vertex labels with their prompt set version, and do not pool them with v2 labels as if they came from one protocol.

### Prompt set v4: self-correction rubric (implemented October 9, 2026)

Prompt set `boros-judge-calibration-prompts-v4` (SHA-256 `2ba6fa7c060c9441db2cf8de37778b038fb1233eef3baabf82ab02ea6bbd7786`) is prompt set v3 plus one sentence in the verdict prompt. The sentence applies the user's [self-correction decision](#self-corrections-user-decision-october-9-2026):

> If the response contradicts itself, for example by first stating a wrong answer and then correcting it, answer no, even if the correct answer also appears in the response.

- **Placement.** The upstream function still renders the prompt. The sentence is then inserted once, at the end of the upstream rubric paragraph, immediately before the first `\n\nQuestion: `. Every upstream category template, abstention included, has exactly that boundary, and it comes before any item text. It is preceded by one space unless the paragraph already ends with a space, so removing the space and the sentence gives back the v3 prompt byte for byte. A rendered prompt without the boundary is refused (`upstream_prompt_rubric_anchor_missing`); it is never sent without the sentence.
- **Unchanged from v3:** the upstream function and its pin, the reply-format system line, the sufficiency prompt and its line, parsing, thinking `between_tools`, the provider-default effort and 512 output tokens. The component hashes are unchanged: verdict `85fa445a…c40c`, sufficiency `c6044858…b857`, upstream `ecce9c4c…5251`, reply instructions `8ecc9d7d…cbcb`, prompt set v3 `b6bcccc2…317c`. The new component is `VERDICT_RUBRIC` (version `boros-judge-calibration-verdict-rubric-v1`, SHA-256 `c48e871665f960068000822f9b017a0dcf36b0bf7785f750c97e4cad665954af`). Verdict prompts grow by 171 characters.
- **Declaration version 4.** Format `boros-judge-calibration-vertex-declaration-v4`, template `scripts/judge_calibration_declarations/vertex-sonnet.v4.template.json` (Sonnet only). It is the version 3 template with a new format, a new status and a `prompts` block that pins prompt set v4 and adds `verdict_rubric_sha256`. `check-declaration` applies every version 3 rule. It refuses (`prompt_hash`) a v3 prompts block in a v4 declaration, a v4 block in a v3 declaration, and a missing or changed rubric hash. The runner records prompt set v4 and the rubric hash in the run record, the labels and every report. Version 1, 2 and 3 declarations, and their request bodies, are unchanged.
- **Status.** Prompt set v4 is a candidate. It is not the default judge.

## Judge runner (implemented, not run)

`scripts/judge_calibration_run.py` runs one judge per invocation over the frozen set. Hosted Jev is out of scope.

| Judge | Route | Transport |
|---|---|---|
| `vertex-opus`, `vertex-sonnet` | `vertex_anthropic.py` with the model chosen per run; version 2 declarations add structured outputs and per-model thinking controls, version 3 replaces structured outputs with the reply-format system line (below) | Application Default Credentials through gcloud; pinned endpoint, no proxy, no redirect |
| `jevk5` | `StdioMCP` from `jevk5_saved_qa.py`: the supplied `mcpme connect --slot` command, `jevk5_decide` tool | Model identity (ID, SHA-256, profile, context) checked on connect and in every decision; the mcpme executable hash must equal the declared one before connecting |
| `qwen-local` | `http://127.0.0.1:11234/v1/chat/completions`, model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` | Loopback only, no proxy, no redirect; temperature 0, thinking off, model echo checked. Model-instance identity is unobservable through mlx-serve, as recorded in [provider admission](PROVIDER-ADMISSION.md). |

Contract:

- **Input.** `items.json` from `assemble`, verified against the manifest's items hash, set ID and item count, plus a declaration whose `calibration_set` matches the manifest. The runner never opens `key.json`; the tests run it with the key file deleted. Requests are rendered only from the item's question, date, category, unanswerable flag, reference, evidence and answer. The item ID, model identity, run, arm and prior labels are never sent.
- **Two gates.** `--execute` refuses unless `check-declaration` reports no problem (exit code 2, nothing dispatched). Without `--execute` the command is a dry run: it validates the set and declaration, renders every request in memory, writes nothing and prints counts only. The dry run makes no network, Vertex token-count, gcloud, MCP or model-server call.
- **Order and replicates.** Deterministic order: replicate, then item ID, then sufficiency before verdict. Each replicate re-sends the identical request. Vertex replicates sample at the provider default; Qwen replicates at temperature 0 are close to deterministic; JevK5 reports a cache for identical requests, so its replicates can be cache hits, and the report counts them.
- **Vertex cost fence.** Per session: one unbilled access probe (an empty generation body must be refused with HTTP 400; 404 halts as no access), then a free counting pass over every pending request, then a refusal of the whole session if the earlier reservations plus counted input and maximum output for every pending request, at the declared prices, exceed the cap. Before each generation the counted cost is reserved again and the request is refused if the cumulative reservation would exceed the cap. Reservations never decrease, including for failed and interrupted requests, and they carry across resumed sessions.
- **Limits and stops.** Declared request limits are cumulative across sessions. A request whose model-visible prompt exceeds a local judge's declared `max_prompt_characters` is recorded as not dispatched. Infrastructure failures (any HTTP status, transport failure, MCP failure) stop the session when `stop_on_first_infrastructure_failure` is true, which every template sets; otherwise they are recorded. Automatic retries happen only up to the declared `automatic_retries`, which is 0 in every template and must be 0 for Vertex. A model identity mismatch always stops the session.
- **Failures are labels of nothing.** A parse failure, refusal, truncated reply or tool error is recorded per request with a fixed code, and the label stays empty. It is never mapped to accept or reject. Vertex codes under a version 2 or version 3 declaration: `output_off_schema` (status `parse_failed`), `response_incomplete` (stop reason `max_tokens`, including a reply that is only a thinking block), `refusal` (stop reason `refusal`) and the adapter's other shape codes (status `response_invalid`). A model identity mismatch is checked before the stop reason and halts the session.
- **Vertex reply metadata.** Every Vertex generation receipt records `stop_reason` (a known value, or `other`) and `thinking_tokens` (from `usage.output_tokens_details.thinking_tokens` when the provider reports it, else null); under version 3 it also records `reply_wrapper` (`bare`, `fenced`, or null when no label). Each session report adds `replies_session` (stop reason counts, summed thinking tokens and, for version 3, wrapper counts), `reply_schemas` (version 2 only, else null), `reply_format` (version 3 only, else null) and `request_fields` (the field names of the generation and count bodies). Version 3 run records and labels files carry `reply_format` and the prompt set v3 hashes; version 1 and 2 records are unchanged.
- **Captures and resume.** Each attempt writes `request`, `intent`, `response` and `receipt` files (0600, in 0700 directories) under the run directory. A destination must be fresh unless `--resume` is given, and a resume requires the same declaration hash, set, prompts and request plan. On resume, every earlier attempt is re-authenticated by hash and by re-deriving its label from the captured response; any mismatch refuses the resume. Completed, unparseable and not-dispatched requests are reused, never re-sent. Requests that failed on infrastructure or were interrupted after dispatch are sent again as a new attempt, which counts against the limits and the cap. Declare request limits with headroom above the plan if resumed failures should be possible.
- **Outputs.** Per session: `labels-session-NN.json` and `report-session-NN.json` in the run directory. When every request is terminal, the labels are also written to the declared `outputs.labels_path`, which must be under `.build` and must not exist. Labels use format `boros-judge-calibration-labels-v1` with one `{verdict, sufficiency}` entry per replicate and `judge` set to the score column name (`jevk5-mcp` for the `jevk5` runner judge). Items with no definite label are omitted. The report holds counts by status and stage, fixed failure codes, call counts, token and cost totals, the probe result and hashes; no text. Requests run sequentially, within every template's concurrency limit.

### Vertex request bodies

Field names only. Under versions 1 and 2, `system` is present for sufficiency requests only; under version 3 it is present for both stages (it holds the reply-format line). No body carries `temperature`, `top_p`, `top_k`, `output_format` or `budget_tokens`.

| Declaration | Generation body | Count body |
|---|---|---|
| Version 3, `vertex-sonnet` | `anthropic_version`, `messages`, `system`, `max_tokens` (512), `thinking: {"type": "between_tools"}`; no `output_config` | `anthropic_version`, `model`, `messages`, `system` |
| Version 3, `vertex-opus` | `anthropic_version`, `messages`, `system`, `max_tokens` (2,048), `output_config: {effort: "low"}`; no `thinking` field, no `format` | `anthropic_version`, `model`, `messages`, `system` |
| Version 2, `vertex-sonnet` | `anthropic_version`, `messages`, `system`, `max_tokens` (512), `thinking: {"type": "between_tools"}`, `output_config: {format}` | `anthropic_version`, `model`, `messages`, `system`, `output_config: {format}` |
| Version 2, `vertex-opus` | `anthropic_version`, `messages`, `system`, `max_tokens` (2,048), `output_config: {effort: "low", format}`; no `thinking` field | the same as Sonnet |
| Version 1, both | `anthropic_version`, `messages`, `system`, `max_tokens` (256) | `anthropic_version`, `model`, `messages`, `system` |

- **Sonnet 5.5:** omitting `thinking` runs adaptive thinking, and `{"type": "disabled"}` returns HTTP 400. `{"type": "between_tools"}` turns thinking off; it takes no other field and is accepted only at effort `high` or below. The template sends no effort, so Sonnet's default effort, `high`, applies.
- **Opus 5.5:** thinking cannot be disabled (`disabled` and `budget_tokens` both return HTTP 400). The template bounds it with `output_config.effort: "low"` and leaves room for thinking plus the reply in a 2,048-token cap. That cap is a judgment, not a measurement; a reply that still hits it is recorded as `response_incomplete`.
- **Counting:** under version 2 the count body includes the same `output_config.format`, because structured outputs add input tokens. Under version 3 it carries the same `system` (with the reply-format line) and `messages` as the generation body and no `output_config`. Thinking and effort do not change the input and are not sent to the count endpoint.
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

Replace `JUDGE` with `vertex-opus`, `vertex-sonnet`, `jevk5` or `qwen-local`. To continue a halted run of the same declaration, repeat the execute command with `--resume`.

Version 3 Vertex runs (instructed JSON), for example Sonnet. Copy the version 3 template, fill it (see [Run declarations](#run-declarations-templates)), then dry run, check and execute into a new run directory and labels path:

```sh
cp scripts/judge_calibration_declarations/vertex-sonnet.v3.template.json \
  .build/judge-calibration/declarations/vertex-sonnet-v3.json
python3 scripts/judge_calibration_run.py --set .build/judge-calibration/set-v1-20261008 \
  --declaration .build/judge-calibration/declarations/vertex-sonnet-v3.json \
  --output .build/judge-calibration/runs/vertex-sonnet-v3-r1
python3 scripts/judge_calibration.py check-declaration .build/judge-calibration/declarations/vertex-sonnet-v3.json \
  --set .build/judge-calibration/set-v1-20261008
python3 scripts/judge_calibration_run.py --set .build/judge-calibration/set-v1-20261008 \
  --declaration .build/judge-calibration/declarations/vertex-sonnet-v3.json \
  --output .build/judge-calibration/runs/vertex-sonnet-v3-r1 --execute
```

For Opus use `vertex-opus.v3.template.json` the same way. Then score, for example:

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

Each still reports only the user-filled fields as problems (authorization, prices and source, cap, request limits, labels path).

Version 3 Vertex dry runs, October 9, 2026, same set from a fresh key-less copy (items and manifest only) in the version 3 worktree, with each version 3 template filled only in `calibration_set`: zero network calls and zero files written. Both report 300 requests (100 distinct), 100 count requests needed, prompt set `boros-judge-calibration-prompts-v3` (`b6bcccc2…317c`), reply-instruction hash `8ecc9d7d…cbcb`, no `reply_schemas`, and only the user-filled fields as problems (13 codes: authorization, prices and source, cap, request limits, labels path). Prompt characters rise by the line's length: sufficiency p50 / max 27,210 / 59,900 (+122), verdict 1,117 / 3,974 (+95).

| Declaration | Output cap | Largest body (bytes) | Plan SHA-256 | Request fields (both stages) |
|---|---:|---:|---|---|
| `vertex-sonnet` v3 | 512 | 60,752 | `aeff9b8a…468c` | `system`; `thinking` `between_tools`; no `output_config`; count body `anthropic_version`, `messages`, `model`, `system` |
| `vertex-opus` v3 | 2,048 | 60,750 | `710d676e…339b` | `system`; no `thinking`; `output_config` `effort`; count body the same as Sonnet |

With the current code, the version 1 Sonnet pass's declaration still passes `check-declaration`, its stored run record matches, and all 100 attempts and 96 counts re-authenticate from its captures (checked read-only), so it remains resumable and verifiable. Rechecked read-only after the version 3 change: the same holds for the version 1 pass, and for the halted version 2 run (1 attempt and 96 counts re-authenticate, run record matches).

JevK5 finding: its context is 8,192 tokens, and the template bound of 24,000 characters is an estimate of about three characters per token, not a measured tokenizer ratio. Under that bound, 31 of the 50 sufficiency requests would be recorded as not dispatched, so JevK5 could produce sufficiency labels for at most 19 items. All 50 verdict requests fit. The real token counts are unverified; JevK5 reports input tokens only after a call.

## Run declarations (templates)

Templates under `scripts/judge_calibration_declarations/` contain no private data. Copy a template to `.build/judge-calibration/declarations/` before filling it, because a filled declaration holds the user's authorization record. New Vertex runs in `llm-train-482420` use the version 3 templates `vertex-opus.v3.template.json` and `vertex-sonnet.v3.template.json`, format `boros-judge-calibration-vertex-declaration-v3`, while the organization policy blocks structured outputs. The version 2 templates stay at `vertex-opus.template.json` and `vertex-sonnet.template.json`, format `boros-judge-calibration-vertex-declaration-v2`, for a project or policy where structured outputs are allowed; `check-declaration` and the runner still accept them. The version 1 templates are kept as `vertex-opus.v1.template.json` and `vertex-sonnet.v1.template.json`; `check-declaration` and the runner still accept version 1, with its unconstrained bodies and bare-text parsing, so runs made under it (the first Sonnet pass) can be resumed and verified unchanged. Version 1 has no thinking control and should not be used for new runs. The version 4 template `vertex-sonnet.v4.template.json`, format `boros-judge-calibration-vertex-declaration-v4`, is the version 3 Sonnet template with [prompt set v4](#prompt-set-v4-self-correction-rubric-implemented-october-9-2026); it is for the candidate only, and the default judge keeps the version 3 template.

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

The version 3 templates fix the same values as version 2 (thinking, effort, output caps, route, gates, replicates) with three differences: the `prompts` block pins prompt set `boros-judge-calibration-prompts-v3` and adds `reply_instructions_sha256`; there is no `reply_schemas` block; and a `reply_format` block pins `mode` `instructed-json`, `structured_outputs` false, the reply-instruction version and SHA-256, and `parse_tolerance` `["surrounding_whitespace", "single_markdown_code_fence"]`. For version 3, `check-declaration` applies every version 2 thinking, effort and output-cap rule above and also refuses: any `output_config` object containing `format`, any `output_format` key or any `reply_schemas` block anywhere in the declaration (`structured_outputs_forbidden`); a `reply_format` block that differs from the code (`reply_format_hash`); and a `prompts` block that is not the v3 set, including a version 2 prompt block or a missing reply-instruction hash (`prompt_hash`). A version 1 or 2 declaration that pins prompt set v3 is refused with `prompt_hash`, and a local judge declaration with the version 3 format is refused with `format`.

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

The same day the user settled the verdict rubric and added the faithful field, and a revised file applies those decisions; see [Revision of October 9, 2026](#revision-of-october-9-2026). **The revised (v2) file is the current 50-item reference adjudication ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)); adjudication v3 is superseded.** The totals and the sufficiency comparison immediately below are the first export's, kept as recorded.

### Totals (first export)

| Measure | Count |
|---|---:|
| Accepted | 43 |
| Rejected | 7 |
| Pack sufficient / insufficient | 28 / 22 |
| Unsupported claims flagged | 0 |
| Sufficiency changed after reveal | 0 |

- **By answerer:** all 15 Sol answers accepted; Qwen 28 of 35. All seven rejects are Qwen answers: three temporal reasoning, two preference, two assistant recall.
- **Adjudication rules observed beyond the protocol:** an answer that first gives a wrong value and then corrects itself was rejected (2 items), and an answer that gives no answer or restates the question was rejected. The upstream judge prompt accepts a response that "contains" the correct answer, so upstream-prompt judges are expected to disagree with these two self-correction items. The self-correction rule became a user decision later the same day; see [Self-corrections](#self-corrections-user-decision-october-9-2026).
- **Correct-plus-unsupported stratum:** both items were accepted without the unsupported flag, against their prior source-aware labels.

### Sufficiency against the annotation proxy (first export)

For the 37 answerable items, human sufficiency agrees with "every annotated positive turn delivered" on 33 (89 percent): 23 sufficient with all delivered, 10 insufficient without. Three were sufficient without every annotated turn and one insufficient with all of them. This supports R2's annotation proxy as a measure of sufficient evidence, on this sample. Eleven of 13 abstention items were marked insufficient, reading "insufficient" as "the evidence lacks the information"; abstention sufficiency labels therefore do not follow the protocol's definition and are excluded from sufficiency agreement.

In the first export, ten of the 11 answerable items with insufficient evidence had accepted answers, nine of them declines. The revision rejects those declines (below).

### Revision of October 9, 2026

User decisions of October 9, 2026: the answer verdict means agreement with the reference under the LongMemEval tolerances, so a decline on an answerable question is a reject even when the evidence lacked the answer (the sufficiency field captures that retrieval failure); and a new **faithful** field records whether the answer is honest about and consistent with the delivered evidence. The coordinator applied these decisions to the first export as a v2 revision, at `.build/judge-calibration/adjudications-jc-9adfaeeb572b8380-v2.json` (private; SHA-256 `7fb07112939eab8688f4559c853e5a511a0fde9f9362a4d03302dc96517140fb`). Its revision block names the first export's SHA-256 (`503e8142…5ce`), and `score --original-adjudications` verified it: the 13 listed items are exactly the difference between the two files (13 verdict changes, 1 sufficiency change, 10 faithful values), with no unlisted change.

**In force again (user decision, October 9, 2026, latest).** Later the same day, the user briefly reversed the decline part of this revision ([adjudication v3](#decline-rule-change-user-decision-october-9-2026-later-the-same-day)). The user then withdrew that reversal ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)). This v2 file, unchanged, is the current 50-item reference adjudication. The figures in this section and the next describe it.

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

1. Extend the set with at least 25 likely-wrong answers (recent-only, insufficient-pack and earlier rejected attempts), adjudicated the same way, so false-accept intervals can separate judges. Assembled October 9, 2026 as the 29-item [extension set](#likely-wrong-extension-set-assembled-and-adjudicated-october-9-2026) `jx-6dbd69dec7456178`, with 7 self-correction candidates. The user adjudicated it the same day: 25 accepted and 4 rejected under the withdrawn rule, 5 and 24 in the final reference file. Both prompt sets judged it ([result](#prompt-sets-v3-and-v4-on-79-items-measured-october-9-2026)).
2. Run the four built judge runners over the 50 items under filled declarations, after authorization.
3. Re-judge the Qwen-labelled records that inform current claims with the best-calibrated judge.

## Vertex Sonnet, declaration version 3 (measured, October 9, 2026)

One authorized run of `claude-sonnet-5-5` over all 50 items with three replicates (300 requests), declaration version 3 (thinking `between_tools`, instructed JSON reply, prompt set `boros-judge-calibration-prompts-v3`), scored against the revised adjudication. Private run: `.build/judge-calibration/runs/vertex-sonnet-v3-r3/`; score report `.build/judge-calibration/score-sonnet-v3-r3.json`. Observed cost $3.76 (1,765,503 input and 23,108 output tokens) under an $8 cap.

| Measure | Result |
|---|---|
| Verdict replies parsed | 150 of 150; all 50 items labelled |
| Error against the revised adjudication (majority of three) | 2/50, 4% (1-13%) |
| False reject | 1/30, 3% (1-17%) |
| False accept | 1/20, 5% (1-24%) |
| Replicate verdict agreement | 98.7%; two items split 2-1 |
| Sufficiency replies parsed | 44 of 150 (105 `output_off_schema`, 1 `response_incomplete`) |
| Sufficiency agreement where labelled | 16/19, kappa 0.69 |

- **The two disagreements were both predicted.** item-011 is a self-correction (wrong value, then right), which the adjudication rejects and the upstream prompt's "contains the correct answer" accepts; Sonnet split 2-1 toward accept. item-048 is the borderline preference answer; Sonnet rejected it in all three replicates.
- **Sufficiency failures have one shape.** 104 of the 105 off-schema replies give a short explanation and end with the requested JSON object. The strict parser refuses them by design. Re-parsing the saved replies with a declared "final JSON object" rule would need no new calls, but the rule would be chosen after seeing the replies.
- **Comparability.** These labels come from prompt set v3; the upstream-only judges did not see the added format line.
- **Cost by task.** Summed from the generation receipts: the 150 verdict requests used 64,245 input and 1,738 output tokens ($0.15 at the declared $2 and $10 per million). The 150 sufficiency requests, which carry the delivered evidence, used 1,701,258 and 21,370 ($3.62).

## Vertex Sonnet, prompt set v4 candidate (measured, October 9, 2026)

The user authorized the run in chat on October 9, 2026. It used `claude-sonnet-5-5` under a filled version 4 declaration (prompt set v4, thinking `between_tools`, instructed JSON, provider-default effort, 512 output tokens). It ran the verdict task only, on all 50 items, with three replicates, majority vote and ties `unknown`. Scored against the revised adjudication, which the [self-correction rule](#self-corrections-user-decision-october-9-2026) leaves unchanged.

Private paths in the coordinator worktree:

- run directory: `.build/judge-calibration/runs/vertex-sonnet-v4-r3/`
- declaration: `.build/judge-calibration/declarations/vertex-sonnet-v4-r3.json`
- labels: `.build/judge-calibration/labels-vertex-sonnet-v4-r3.json`, SHA-256 `6eac0ff1…1d82e`
- score report: `.build/judge-calibration/score-sonnet-v4-r3.json`

The run was executed in worktree `agent-a84af31c74213f506` and copied with modes preserved.

| Measure | Prompt set v3 (default judge) | Prompt set v4 (candidate) |
|---|---|---|
| Verdict replies parsed | 150 of 150 | 150 of 150 (all bare JSON, `end_turn`, 0 thinking tokens) |
| Error (majority of three) | 2/50, 4% (1-13%) | 2/50, 4% (1-13%) |
| False reject | 1/30, 3% (1-17%) | 2/30, 7% (2-21%) |
| False accept | 1/20, 5% (1-24%) | 0/20, 0% (0-16%) |
| Replicate verdict agreement | 98.7%, two items split 2-1 | 100%, every item 3-0 |
| `unknown` labels | 0 | 0 |

Item by item, the two prompt sets give the same majority verdict on 48 of 50 items:

- **item-011, the self-correction:** v3 accepted it 2-1, a false accept. v4 rejects it 3-0, which is correct. The other self-correction, item-010, is rejected by both.
- **item-024, a preference answer the adjudication accepts:** v3 accepted it 2-1. v4 rejects it 3-0, a new false reject. That answer does not contradict itself. Replies are bare verdicts, so why the added sentence turned this one is not known.
- **item-048, the borderline preference answer:** both reject it 3-0, the same false reject as before.

Both v4 false rejects are preference items. Preference false rejects rise from 1 of 2 to 2 of 2 adjudicated accepts, a very small cell.

**The gpt4_70e84552 replay answers under v4.** These are the four self-contradicting answers the default judge split 3 to 1 on, described in [Why gpt4_70e84552 was rejected](ANSWER-PRESENTATION-DEFECTS.md#why-gpt4_70e84552-was-rejected-read-locally-at-the-users-request-october-9-2026). The set was built with the new `subset` command as `js-d85a8619fb138bf1` (4 items, items SHA-256 `0dac6f2b…33dd`) from judge sets `jr-d978990efd3d8096` and `jr-ffadbd1ee098c5a5`, items copied unchanged under new opaque IDs. A second declaration within the same authorization judged it. All 12 replies parsed and all four answers were rejected 3-0:

| Answer | Default judge (v3) | v4 |
|---|---|---|
| Hybrid retrieval, V3 framing | accept 3-0 | reject 3-0 |
| Hybrid retrieval, V4 framing | accept 3-0 | reject 3-0 |
| Lexical retrieval, V3 framing | accept 3-0 | reject 3-0 |
| Lexical retrieval, V4 framing | reject 3-0 | reject 3-0 |

Labels SHA-256 `475f80cf…3e05`. Private paths in the coordinator worktree: `.build/judge-calibration/set-gpt4_70e84552-replays/`, `runs/vertex-sonnet-v4-gpt4_70e84552/` and `labels-vertex-sonnet-v4-gpt4_70e84552.json`. v4 applies the user's rule to all four, as the rubric requires.

**Cost.** The probe ran first: a standalone access probe and each runner session's probe all returned `reachable` (400 on an empty body). The calibration run cost $0.159774 observed (71,217 input and 1,734 output tokens). Its reservation was $0.910734 against a $0.95 cap. The gpt4_70e84552 run cost $0.018822 observed (8,751 input and 132 output tokens). Its reservation was $0.078966 against a $0.84 cap, which is $1.00 minus the first run's observed cost. Total observed: $0.178596, within the authorized $1.00. Request limits were 160 generations and 60 counts, then 15 and 6. Each leaves room for one resume, and neither run needed one.

**Reading.** On this set v4 trades one false accept (the self-correction) for one false reject (a preference answer). The overall error is unchanged at 2/50, and the intervals overlap completely. The calibration set has only two self-correction items. A difference in self-correction handling cannot be separated on it: v4 is 2 of 2 correct there and v3 is 1 of 2. The four replay answers show the same direction outside calibration, 4 of 4 rejected against 1 of 4. Telling the two prompt sets apart needs the [likely-wrong extension](#likely-wrong-extension-set-assembled-and-adjudicated-october-9-2026), which holds 7 self-correction candidates, after human adjudication. Prompt set v4 is recorded as a candidate. The default judge stays prompt set v3 until the coordinator and the user decide.

## Likely-wrong extension set (assembled and adjudicated October 9, 2026)

The extension adds plausible wrong answers and self-corrections, so that false-accept intervals can separate judges. It was assembled with the same tool, the same blinding and opaque item IDs, the same key and manifest formats and the same local form as the base set. The user adjudicated it on October 9, 2026, before any judge saw it ([result](#human-adjudication-of-the-extension-measured-october-9-2026)); both prompt sets then judged it ([result](#prompt-sets-v3-and-v4-on-79-items-measured-october-9-2026)).

```sh
python3 scripts/judge_calibration.py assemble-extension \
  --seed boros-p4-judge-calibration-extension-v1-20261009 \
  --evaluation-root /Users/johnshahbazian/development/boros/.build/evaluation \
  --evaluation-root /Users/johnshahbazian/.codex/worktrees/native-investigation/boros/.build/evaluation \
  --replay <agent-aca195077f142adad>/.build/answer-presentation-retrieval-on-20261009 \
  --replay <agent-a87693523abe04f90>/.build/answer-presentation-lexical-on-20261009 \
  --replay <agent-acaa09013cb88fa18>/.build/answer-presentation-recent-only-20261009 \
  --dataset <pinned longmemeval_s_cleaned.json> \
  --base-set <coordinator>/.build/judge-calibration/set-v1-20261008 \
  --output .build/judge-calibration/set-x1-20261009
```

**Candidates.** The candidates are the earlier inventory (192 eligible attempts) plus the October 9 replays: hybrid retrieval-on, lexical retrieval-on (ordinary Send) and recent-only, 126 runs and 124 eligible answers. The replays have no inventory of their own. `replay_candidates` reads each declared attempt and checks its answer against the runner's digest. It resolves the delivered evidence from the pinned dataset, verifying each byte range by digest; all replay evidence verified. Gold delivery comes from the replay's own `measure.json`. Where the replay was judged, the default judge's majority verdict is attached as the prior label `vertex-sonnet-default-qa`. Answers already in the base set, matched by question and answer digest, are excluded (50).

**Strata, by precedence.**

1. **Self-correction:** the lexical heuristic `boros-judge-calibration-self-correction-heuristic-v1` fires. It has two signals:
   - an explicit revision marker, such as a "Correction" heading, "Wait,", "Actually," or "let me re-read";
   - "late reference": the first paragraph states a bold headline of the reference's kind (numeric or not) that does not contain the reference, and the last paragraph does contain it. This signal applies only to answerable questions whose reference is at most six normalized tokens.
2. **Rejected:** every prior verdict rejects.
3. **Recent-only:** an answerable question answered on a recent-only arm.
4. **Insufficient pack:** any other answerable answer whose delivery missed an annotated evidence turn.

Answers in none of these strata are not candidates. Membership in the self-correction stratum depends on the answer text and the reference, by construction. Membership in the other strata uses metadata and prior labels only, as in the base set. Order inside every stratum is a seeded hash.

**Caps.** The quotas are 8, 8, 7 and 7, with a minimum of 25 items, and the assembly refuses to write a set with fewer than 6 self-correction items. Outside the base set, the heuristic found self-contradicting answers to only three distinct questions. With the base set's cap of 2 per question, the stratum could reach only 5 items. It therefore admits up to 3 items per question, but never more than 2 from one question and one run family. That limit is what keeps the gpt4_70e84552 replay answers to at most two. Every other stratum keeps the cap of 2 per question.

| Property | Value |
|---|---|
| Set ID | `jx-6dbd69dec7456178` |
| `items.json` SHA-256 | `8887fbc08ad008185368af25f9ee4d4088ca3109ddc9ff20de90318c7bd2bcd9` |
| Form SHA-256 | `1aaaf4f8328db360cc2ccbc4ce39bed11d22944d1bbc0390a8b984952539e09b` |
| Items / distinct questions | 29 / 18 |
| By stratum | self-correction 7, rejected 8, recent-only 7, insufficient pack 7 (no fill items) |
| Candidates after deduplication | self-correction 11, rejected 58, recent-only 43, insufficient pack 13 |
| Shortfall | self-correction 1 against its quota of 8 |
| By category | multi-session 6, temporal reasoning 6, preference 5, knowledge update 4, assistant recall 4, user recall 4; no abstention item |
| By answerer | Qwen 27, Sol 2, Anthropic 0 |
| By source | October 9 replays 11 (hybrid 3, lexical 3, recent-only 5), earlier inventory 18 |
| Self-correction composition | 3 questions contribute 3, 3 and 1 items. The gpt4_70e84552 question contributes 2 replay answers and 1 earlier answer. Signals: explicit revision 3, late reference 6 (some items have both) |
| Identifier substitutions / answers naming a model | 29 / 0 |

- **Heuristic precision.** The heuristic only proposes candidates. Before it was finalized, the assembling agent read its hits locally. Requiring a bold headline of the reference's kind removed hits that were consistent answers (knowledge-update listings, a premise stated in bold, a component value stated first). On that reading, all 7 selected items state a wrong value first. Two of them end with a hedge ("if you count only ..., it is two") rather than a correction. That reading is not adjudication.
- **Blinding.** As in the base set: the key holds stratum, run, arm, model, prior labels and the heuristic's signals. **The adjudicator should not open `key.json` before exporting decisions.** Item IDs do not reveal stratum, because the order is a separate seeded hash.

### Opening the extension form

Private files in the coordinator worktree, all mode `0600` in `0700` directories and ignored by Git:

- `.build/judge-calibration/set-x1-20261009/items.json`
- `key.json`
- `manifest.json`
- `adjudication-form.html`

The set was assembled in worktree `agent-a84af31c74213f506` and copied with modes preserved.

1. Open `.build/judge-calibration/set-x1-20261009/adjudication-form.html` in a desktop browser, from the coordinator worktree. It is the same self-contained, network-free form as the base set's. It records sufficiency, then reveals the answer, then records verdict, faithful and an optional note.
2. Apply the [adjudication protocol](#adjudication-protocol), the [category tolerances](#category-tolerances-user-decision-october-8-2026) and the [self-correction rule](#self-corrections-user-decision-october-9-2026).
3. Export the decisions to `.build/judge-calibration/adjudications-jx-6dbd69dec7456178.json`.
4. Score the adjudication on its own with `python3 scripts/judge_calibration.py score --set .build/judge-calibration/set-x1-20261009 --adjudications .build/judge-calibration/adjudications-jx-6dbd69dec7456178.json`. Any judge run over the extension needs its own authorization after that.

### Human adjudication of the extension (measured, October 9, 2026)

The user adjudicated all 29 items with the form, under the [decline-rule change](#decline-rule-change-user-decision-october-9-2026-later-the-same-day), and exported format v2 with faithful recorded on every item. The export's `adjudicator` field is blank; the adjudicator is the user. Private file `.build/judge-calibration/adjudications-jx-6dbd69dec7456178.json`, SHA-256 `1b2d7abe912b22e82adc0041e1c0a167664d1d1cb7f53dbdab5d8637ca3775e9`. The file is used unchanged. Notes stay private.

| Measure | Count |
|---|---:|
| Accepted / rejected | 25 / 4 |
| Accepted declines on answerable questions (verified by the coordinator by reading) | 14: items 001, 002, 006, 011, 015, 016, 018, 020, 021, 024, 026, 027, 028, 029 |
| Pack sufficient / insufficient | 6 / 23 |
| Faithful yes / no | 28 / 1 (item-013, accepted) |
| Unsupported claims flagged; sufficiency changed after reveal | 0; 0 |
| Verdict / faithful / sufficiency | accept, yes, insufficient 21; accept, no, insufficient 1; accept, yes, sufficient 3; reject, yes, sufficient 3; reject, yes, insufficient 1 |

By sampling stratum:

| Stratum | Items | Accepted | Rejected | Accepted declines |
|---|---:|---:|---:|---:|
| Self-correction | 7 | 3 | 4 | 0 |
| Rejected (every prior judge rejected) | 8 | 8 | 0 | 3 |
| Recent-only | 7 | 7 | 0 | 7 |
| Insufficient pack | 7 | 7 | 0 | 4 |

- **Self-correction stratum.** The four rejects are items 004, 008 and 009 (all three on question gpt4_70e84552) and item-017. The three accepts, items 010, 012 and 022, are all on question 00ca467f. The heuristic flagged them, but the user did not judge them to be self-corrections. The coordinator's summary gave this stratum as 3 rejected and 4 accepted. The file and the score both give 4 rejected (item-017 is a reject in this stratum) and 3 accepted.
- **Sufficiency against the annotation proxy.** The six sufficient packs are exactly the six items with every annotated turn delivered, so agreement is 29 of 29.
- **Rejected stratum.** Every prior judge had rejected these 8 answers against the reference. Under the withdrawn rule the user accepted all 8 as right given the evidence: 3 are declines and 5 are non-decline answers on insufficient packs. In the [final reference adjudication](#decline-rule-reversal-user-decision-october-9-2026-latest) all 8 are rejects.
- **Use of this export.** The figures above describe the user's export as recorded under the withdrawn rule. The extension's reference adjudication is the final `-reference-v2` file, a verified revision of this export with 20 verdicts flipped to reject (5 accepted, 24 rejected).

## Prompt sets v3 and v4 on 79 items (measured, October 9, 2026)

The user authorized the run in chat on October 9, 2026. It judged the 29 extension items with both prompt sets:

- the default judge: prompt set v3, declaration version 3;
- the candidate: prompt set v4, declaration version 4.

Both used Vertex `claude-sonnet-5-5`, `llm-train-482420`, `global`, thinking `between_tools`, instructed JSON and the provider-default effort. Both ran the verdict task only, with three replicates, majority vote and ties `unknown`. The output cap was 64 tokens instead of 512, as in the [framing V5 run](FRAMING-V5.md). Prompt, reply format, model and replicate count are unchanged, and these define the judge.

The 50-item labels are the existing runs: `labels-vertex-sonnet-v3-r3.json` (`5580307c…1864`) and `labels-vertex-sonnet-v4-r3.json` (`6eac0ff1…d82e`). The run was executed in worktree `agent-ac5e342aa38cfe89a` and copied with modes preserved into the coordinator worktree. Private paths there:

- declarations `declarations/vertex-sonnet-{v3,v4}-x1-r3.json`
- runs `runs/vertex-sonnet-{v3,v4}-x1-r3/`
- labels `labels-vertex-sonnet-v3-x1-r3.json` (`d569536a…7842`) and `labels-vertex-sonnet-v4-x1-r3.json` (`a114065c…6294`)
- score and pooled reports against the first targets (history): `scores-20261009-decline-rule/`
- score and pooled reports against the final reference target: `scores-20261009-reference-final/`

**Run.** A standalone access probe and each session's probe returned `reachable` (HTTP 400 on an empty body). Each prompt set made 29 count requests and 87 generations. All 174 replies parsed: bare JSON, `end_turn`, 0 thinking tokens, a mean of 11.3 (v3) and 11.1 (v4) output tokens. Every extension item was unanimous, 3 to 0, under both prompt sets, so there is no `unknown`. Cost:

- v3: $0.106614 observed (48,402 input and 981 output tokens), $0.152658 reserved under a $0.30 cap.
- v4: $0.114522 observed (52,431 input and 966 output tokens), $0.160716 reserved under a $0.30 cap.
- Total: $0.221136, within the authorized $0.60. Request limits were 100 generations and 60 counts per declaration, which allowed one resume. Neither run needed one.

### Against the final reference target (rescored offline, October 9, 2026)

The saved labels were rescored with `score` and `pool-scores`, with no model call. The targets were the 50-item v2 file and the extension's final `-reference-v2` file ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)). Both revisions verified against their original exports. The 50-item rows reproduce the earlier records exactly. Rates are majority-of-three verdicts with 95 percent Wilson intervals.

| Items | Measure | Prompt set v3 (default) | Prompt set v4 (candidate) |
|---|---|---|---|
| All 79 | Error | 9/79, 11% (6-20%) | 8/79, 10% (5-19%) |
| | False reject | 3/35, 9% (3-22%) | 6/35, 17% (8-33%) |
| | False accept | 6/44, 14% (6-27%) | 2/44, 5% (1-15%) |
| 50-item set (v2) | Error | 2/50, 4% (1-13%) | 2/50, 4% (1-13%) |
| | False reject / false accept | 1/30 / 1/20 | 2/30 / 0/20 |
| 29-item extension (final) | Error | 7/29, 24% (12-42%) | 6/29, 21% (10-38%) |
| | False reject / false accept | 2/5 / 5/24 | 4/5 / 2/24 |

Extension per stratum, each cell error / false reject / false accept:

| Stratum (accept, reject) | v3 | v4 |
|---|---|---|
| Self-correction (3, 4) | 4/7, 57% (25-84%) / 1/3 / 3/4 | 3/7, 43% (16-75%) / 3/3 / 0/4 |
| Rejected (0, 8) | 0/8 / none adjudicated accept / 0/8 | the same as v3 |
| Recent-only (0, 7) | 1/7, 14% (3-51%) / none / 1/7 | the same as v3 |
| Insufficient pack (2, 5) | 2/7, 29% (8-64%) / 1/2 / 1/5 | the same as v3 |

Item-level disagreements (IDs only):

- **v3:**
  - false accepts jc-011, jx-004, jx-008, jx-009, jx-024 and jx-029;
  - false rejects jc-048, jx-007 and jx-022.
- **v4:**
  - false accepts jx-024 and jx-029;
  - false rejects jc-024, jc-048, jx-007, jx-010, jx-012 and jx-022.

What changed from the first reference target:

- **The six classified items.** Both prompt sets rejected items 003, 005, 013, 014, 019 and 025, so the six flips remove six false rejects from each. False reject falls from 9/41 to 3/35 for v3 and from 12/41 to 6/35 for v4.
- **False accepts.** The counts are unchanged, over 44 adjudicated rejects instead of 38.
- **Remaining extension false rejects.** These are jx-007, which both prompt sets reject and the reference classification accepts, and jx-022. v4 adds jx-010 and jx-012.
- **Items 024 and 029.** jx-024 and jx-029 are false accepts for both prompt sets. The coordinator checked both: a hedged list containing the reference, and a self-contradiction. Both are rejects under the existing rules, but they are judgment calls. Excluding them, false accept is 4/42 for v3 and 0/42 for v4.

### All 79 items against the first targets (history)

These figures were measured against the first reference target (the extension's derived file, before the six classified flips) and against the withdrawn evidence-relative target. They are superseded by the [rescoring above](#against-the-final-reference-target-rescored-offline-october-9-2026) and kept as history. Rates are majority-of-three verdicts with 95 percent Wilson intervals.

| Target and grader | Measure | Prompt set v3 (default) | Prompt set v4 (candidate) |
|---|---|---|---|
| Reference target, judge | Error | 15/79, 19% (12-29%) | 14/79, 18% (11-28%) |
| | False reject | 9/41, 22% (12-37%) | 12/41, 29% (18-44%) |
| | False accept | 6/38, 16% (7-30%) | 2/38, 5% (1-17%) |
| Evidence-relative target, judge alone | Error | 35/79, 44% (34-55%) | 34/79, 43% (33-54%) |
| | False reject | 31/65, 48% (36-60%) | 34/65, 52% (40-64%) |
| | False accept | 4/14, 29% (12-55%) | 0/14, 0% (0-22%) |
| Evidence-relative target, combined rule (`lexical`) | Error | 20/79, 25% (17-36%) | 19/79, 24% (16-35%) |
| | False reject | 16/65, 25% (16-36%) | 19/65, 29% (20-41%) |
| | False accept | 4/14, 29% (12-55%) | 0/14, 0% (0-22%) |

`lexical-with-partial` gives the same combined figures, because both judges already accept item-024, the only partial decline. With the user's own decline list in place of the classifier, an analysis rather than a mode, the combined rule's error would be 15/79 (v3; false reject 11/65, 17%, 10-28%) and 14/79 (v4; false reject 14/65, 22%, 13-33%).

### Per set (history)

| Set, target and grader | v3 error | v3 false reject | v3 false accept | v4 error | v4 false reject | v4 false accept |
|---|---|---|---|---|---|---|
| 50 items, reference (v2) | 2/50, 4% (1-13%) | 1/30 | 1/20 | 2/50, 4% (1-13%) | 2/30 | 0/20 |
| 50 items, evidence-relative (v3, withdrawn), judge | 12/50, 24% (14-37%) | 11/40 | 1/10 | 12/50, 24% (14-37%) | 12/40 | 0/10 |
| 50 items, evidence-relative, combined | 6/50, 12% (6-24%) | 5/40 | 1/10 | 6/50, 12% (6-24%) | 6/40 | 0/10 |
| 29 items, first reference (derived) | 13/29, 45% (28-62%) | 8/11 | 5/18 | 12/29, 41% (26-59%) | 10/11 | 2/18 |
| 29 items, evidence-relative, judge | 23/29, 79% (62-90%) | 20/25 | 3/4 | 22/29, 76% (58-88%) | 22/25 | 0/4 |
| 29 items, evidence-relative, combined | 14/29, 48% (31-66%) | 11/25 | 3/4 | 13/29, 45% (28-62%) | 13/25 | 0/4 |

The 50-item reference rows reproduce the earlier records exactly.

### Extension per stratum (history)

Each cell gives error / false reject / false accept.

| Stratum (items) | First reference target, v3 | First reference target, v4 | Evidence-relative judge (withdrawn), v3 and v4 | Evidence-relative combined (withdrawn), v3 and v4 |
|---|---|---|---|---|
| Self-correction (7: 3 accept, 4 reject) | 4/7, 57% (25-84%) / 1/3 / 3/4 | 3/7, 43% (16-75%) / 3/3 / 0/4 | as the reference target (no declines in this stratum) | as the reference target |
| Rejected (8) | 5/8, 62% (31-86%) / 5/5 / 0/3 | the same as v3 | 8/8 / 8/8 / none adjudicated reject | 6/8, 75% (41-93%) / 6/8 / none |
| Recent-only (7) | 1/7, 14% (3-51%) / none adjudicated accept / 1/7 | the same as v3 | 6/7, 86% (49-97%) / 6/7 / none | 2/7, 29% (8-64%) / 2/7 / none |
| Insufficient pack (7) | 3/7, 43% (16-75%) / 2/3 / 1/4 | the same as v3 | 5/7, 71% (36-92%) / 5/7 / none | 2/7, 29% (8-64%) / 2/7 / none |

The two prompt sets differ only in the self-correction stratum.

### Item-level disagreements against the first targets (IDs only, history)

`jc-` is the 50-item set, `jx-` the extension.

- **First reference target, v3:**
  - false accepts jc-011, jx-004, jx-008, jx-009, jx-024 and jx-029;
  - false rejects jc-048, jx-003, jx-005, jx-007, jx-013, jx-014, jx-019, jx-022 and jx-025.
- **First reference target, v4:**
  - false accepts jx-024 and jx-029;
  - false rejects jc-024, jc-048, jx-003, jx-005, jx-007, jx-010, jx-012, jx-013, jx-014, jx-019, jx-022 and jx-025.
- **Evidence-relative target, judge alone.** The false accepts are the reference target's self-corrections: jc-011, jx-004, jx-008 and jx-009 for v3, none for v4. The false rejects are the reference target's false rejects plus jc-035 and every accepted decline that both judges reject: jc-002, 012, 014, 015, 023, 025, 031, 038 and 040, and the 12 extension declines other than jx-024 and jx-029 (31 for v3, 34 for v4).
- **Evidence-relative target, combined rule, v3:**
  - false accepts jc-011, jx-004, jx-008 and jx-009;
  - false rejects jc-002, jc-015, jc-023, jc-035, jc-048, jx-003, jx-005, jx-007, jx-011, jx-013, jx-014, jx-019, jx-020, jx-022, jx-025 and jx-027.
- **Evidence-relative target, combined rule, v4:**
  - no false accept;
  - false rejects: the v3 list plus jc-024, jx-010 and jx-012.

### Reading and recommendation

- **Self-corrections.** The user rejected six self-corrections across the 79 items: jc-010, jc-011, jx-004, jx-008, jx-009 and jx-017. v4 rejects all six. v3 accepts four of them (jc-011, jx-004, jx-008 and jx-009). Three of those four are on question gpt4_70e84552, which matches the replay finding.
- **What v4 costs.** v4 also rejects jx-010 and jx-012, two of the three 00ca467f answers the user accepted, and jc-024, a preference answer. Both prompt sets reject jx-007, jx-022 and jc-048. So v4 trades 4 false accepts for 3 false rejects.
- **Final reference target.** Against it, v3 has 9/79 errors and v4 8/79 ([rescoring](#against-the-final-reference-target-rescored-offline-october-9-2026)). v4's two false accepts are jx-024 and jx-029, the two flipped declines that both prompt sets accept and whose flip is unchecked. On the other 77 items, false accept is 0 of 42 adjudicated rejects for v4 and 4 of 42 for v3.
- **Statistics.** Every overall interval overlaps, so 79 items do not separate the prompt sets statistically.
- **Recommendation (the user decides; the default is unchanged).** Use prompt set v4 as the default judge for the reference-correct measure. A false accept inflates an accepted-answer count directly, and v4's false accepts on the 77 undisputed items are 0 of 42 against v3's 4 of 42. v4 applies the user's self-correction rule as written. Its extra false rejects fall on one question family and one preference item.

  Caveat: a change of default is a new judge configuration whose rates are the v4 column of the rescoring.
- **Evidence-relative grading: withdrawn.** Against that target, neither prompt set graded alone: about half of the evidence-relative accepts were false rejects. The combined rule's 24 to 25 percent error was not adequate either. The user withdrew the target ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)), so no further grader is proposed for it.

## Default judge (user decision, October 9, 2026)

The user selected Vertex Sonnet 5.5 as the default evaluation judge. Plan P4 step 3 asks for the judge with the lowest error. Sonnet is the only candidate run over all 50 items. The earlier judges were scored only on the historical labels they already had, on 13 to 27 items each (Qwen 2/27, JevK5 1/18, Sol 0/13). Sol's 0/13 has an interval of 0-23 percent, too wide to separate it from Sonnet, and Sonnet costs less. This is a selection by the user on that evidence, not a measured win over every candidate.

- **Scope: answer verdicts only.** Use it for accept or reject against the reference, with the upstream LongMemEval verdict prompt and the [category tolerances](#category-tolerances-user-decision-october-8-2026). Its sufficiency labels are not used: 105 of 150 replies failed the strict parser, so A1 packs keep the human sufficiency labels. Whether to re-parse the saved replies with a declared final-JSON rule is still open.
- **Configuration.** Use declaration version 3 (`scripts/judge_calibration_declarations/vertex-sonnet.v3.template.json`) with prompt set `boros-judge-calibration-prompts-v3`, thinking `between_tools`, an instructed JSON reply, no temperature, and the provider default effort. Run three replicates per item. A majority vote decides; a tie or an unparseable majority is `unknown` and is reported, never counted as accept. A run that changes the prompt, the reply format, the model or the replicate count is a different judge and needs its own calibration against this set.
- **Rates attached to every later acceptance.**

  | Measure | Rate (95% Wilson interval) |
  |---|---|
  | Error | 2/50, 4% (1-13%) |
  | False reject | 1/30, 3% (1-17%) |
  | False accept | 1/20, 5% (1-24%) |

  An accepted-answer count is reported with these rates and the run's capture hash. A count produced without this configuration is a model opinion, as before.
- **Rates after the extension (October 9, 2026).** These 50-item rates are against the reference target, the verdict's meaning ([Decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest)). On all 79 items, against the final reference target, the same configuration has error 9/79, 11% (6-20%), false reject 3/35, 9% (3-22%), and false accept 6/44, 14% (6-27%). See [the rescoring](#against-the-final-reference-target-rescored-offline-october-9-2026). Two decisions are for the user:
  - which rates later acceptances carry;
  - whether the default moves to prompt set v4, which is recommended there.

  Until then reports may attach both the 50-item and the 79-item rates. The earlier 79-item figures (15/79 against the first reference target, and the evidence-relative figures) are superseded.
- **Known disagreements.** item-011, a self-correction, is rejected by the adjudication, and Sonnet leans toward accepting it. item-048 is a borderline preference answer, accepted by the adjudication and rejected by Sonnet.
- **Self-correction rule: closed October 9, 2026.** The user decided that self-corrections are rejected ([Self-corrections](#self-corrections-user-decision-october-9-2026)). The default judge's prompt does not state that rule. It accepted 3 of the 4 self-contradicting gpt4_70e84552 replay answers, so its false-accept rate on this kind of answer is probably higher than the calibrated 1/20 suggests. Prompt set v4 adds the rule and is recorded below as a [candidate](#vertex-sonnet-prompt-set-v4-candidate-measured-october-9-2026). The default judge is unchanged until the coordinator and the user decide.
- **Limits.** The false-accept interval reaches 24 percent. 10 of the 20 adjudicated rejects are declines, which are easy to reject. The set has no Claude-authored answers, so self-preference is untested; see [Self-preference](#self-preference). Each run still needs its own authorization, frozen declaration and spending cap.
- **Revisit when** the likely-wrong extension (at least 25 items) narrows the false-accept interval (it now has: 29 items adjudicated and judged October 9, 2026, with the recommendation recorded [there](#reading-and-recommendation)), before Sonnet judges any answer written by Opus or Sonnet, or if the organization policy is changed to allow structured outputs and the judge configuration changes as a result.

### First use outside calibration (October 9, 2026)

The default judge's first run outside the calibration set, authorized by the user, judged the 42 answers of the [retrieval-on replay](ANSWER-PRESENTATION-DEFECTS.md#replay-v3-versus-v4-with-past-conversation-retrieval-on-all-21-questions) (Qwen-authored, so self-preference does not apply).

- **Same judge, verdict task only.** It used the version 3 Sonnet template unchanged except for `execution.stages_per_item: ["verdict"]`, which `check-declaration` and the runner now accept as the only alternative to both stages. Prompts, reply format and parsing are unchanged, and the verdict request bodies are byte-identical to a full plan's (synthetic contract in `scripts/test_judge_calibration_run.py`). Items come from `answer_presentation_replay.py judge-set`, which uses the calibration item builder with no evidence.
- **Run.** One standalone access probe and the runner's probe, both `reachable`. Then 42 count requests and 126 verdict generations. All 126 parsed (bare JSON, `end_turn`, 0 thinking tokens), and all 42 items were unanimous, 3 to 0, so no `unknown`.
- **Cost.** $0.128274 observed (56,742 input and 1,479 output tokens at the declared $2 and $10 per million), $0.758856 reserved under a $1.00 cap.
- **Result.** 31 of 42 accepted (V3 15 of 21, V4 16 of 21), reported with the rates above: error 2/50, false reject 1/30, false accept 1/20. Private run directory: `.build/answer-presentation-retrieval-on-20261009/judge-run-vertex-sonnet-v3/` in the replay's worktree; labels SHA-256 `2c83aba7…de78`.

### Run log

One line per authorized run. Every run uses the configuration above, verdict task only, three replicates, and is reported with error 2/50, false reject 1/30 and false accept 1/20.

- October 9, 2026, [hybrid retrieval-on replay](ANSWER-PRESENTATION-DEFECTS.md#replay-v3-versus-v4-with-past-conversation-retrieval-on-all-21-questions): 42 Qwen answers, set `jr-d978990efd3d8096`, 126 of 126 parsed, 31 of 42 accepted, $0.128274 observed under a $1.00 cap.
- October 9, 2026, [lexical (ordinary Send) retrieval-on replay](ANSWER-PRESENTATION-DEFECTS.md#replay-v3-versus-v4-with-ordinary-sends-lexical-retrieval-all-21-questions): 42 Qwen answers, set `jr-ffadbd1ee098c5a5`. The first session halted on one transport failure at 48 of 126 ($0.048666, labels unused); a full second session parsed 126 of 126 (labels SHA-256 `baf8cc71…9c16`, $0.125522). 31 of 42 accepted. Total $0.174188 observed, kept within the $1.00 authorization by capping the second session at $0.94.
- October 9, 2026, [framing V5 replay](FRAMING-V5.md): 207 Qwen answers (V4, V5 and V4 without G over three cohorts), set `jr-6d3b1c7ae4df92e6`, one session, 621 of 621 parsed (labels SHA-256 `aaf783c5…358e`), 103 of 207 accepted, $0.851556 observed under a $2.00 cap. The output cap was 64 tokens instead of 512 so that the reservation fit the cap; replies averaged 11.5 tokens, all `end_turn`.

Candidate runs that do not use the default configuration are logged separately and carry their own rates:

- October 9, 2026, [prompt set v4 candidate](#vertex-sonnet-prompt-set-v4-candidate-measured-october-9-2026), not the default judge. One authorization with a $1.00 total cap covered two runs, both verdict task only with three replicates.
  - Calibration set `jc-9adfaeeb572b8380`: 150 of 150 parsed, error 2/50, false reject 2/30, false accept 0/20, $0.159774 observed under a $0.95 cap.
  - The four gpt4_70e84552 replay answers, subset `js-d85a8619fb138bf1`: 12 of 12 parsed, all four rejected, $0.018822 observed under a $0.84 cap.
  - Total $0.178596 observed.
- October 9, 2026, [likely-wrong extension](#prompt-sets-v3-and-v4-on-79-items-measured-october-9-2026), set `jx-6dbd69dec7456178`, both prompt sets under one authorization with a $0.60 total cap, verdict task only, three replicates, output cap 64 tokens.
  - Default judge (prompt set v3, declaration version 3): 87 of 87 parsed, all items unanimous, 8 of 29 accepted, labels SHA-256 `d569536a…7842`, $0.106614 observed under a $0.30 cap.
  - Candidate (prompt set v4, declaration version 4): 87 of 87 parsed, all items unanimous, 3 of 29 accepted, labels SHA-256 `a114065c…6294`, $0.114522 observed under a $0.30 cap.
  - Total $0.221136 observed. Rates on all 79 items are recorded per target in the linked section.

## What the user must do and authorize

To start P4 adjudication now (no model calls):

1. Decided October 8, 2026: apply the upstream LongMemEval tolerances (see [Category tolerances](#category-tolerances-user-decision-october-8-2026)). Still open: whether to adjudicate the two-item correct-plus-unsupported stratum as is or add reviewer-constructed items.
2. Open `.build/judge-calibration/set-v1-20261008/adjudication-form.html` locally, adjudicate the 50 items, and export the decisions into `.build/judge-calibration/`. A designated reviewer may do this instead; the export records the adjudicator name. Done October 9, 2026, then revised the same day.
3. Optional: record faithful on the 40 items where it is not adjudicated. The set's original form predates the field; regenerate the form with the `form` command (see [Adjudication format](#adjudication-format)), import the revised file, record faithful, and export. A new export carries no revision block, so keep the revised file as the record of the October 9 changes.
4. Open items after the [decline-rule reversal](#decline-rule-reversal-user-decision-october-9-2026-latest):
   - items 024 and 029 are classified as rejects by the coordinator (see above); the user may overturn either;
   - decide whether prompt set v4 becomes the default judge.

   Settled October 9, 2026:
   - item-035 is a reject again (v2);
   - the 8 non-decline accepts on insufficient packs were classified by the coordinator at the user's instruction (6 rejects, 2 accepts), without a form re-grade.

To run judges, each run needs its own authorization. The runners are built; none has run. For every judge: copy its template to `.build/judge-calibration/declarations/`, fill the fields in the table above, run the dry run, run `check-declaration` until it reports `"complete": true`, then authorize and run the execute command.

1. **Vertex Opus.** Use the version 3 template (version 2 is blocked by the organization policy). Declare current Vertex AI prices for `claude-opus-5-5` with their source and date, a spending cap, and request limits of at least 300 generations and 100 counts. The cap must cover the reservation of counted input plus 2,048 output tokens per request (roughly $19 for 3 replicates at $4 and $20 per million; see the estimate above). Authorizing the run authorizes one unbilled access probe per session, the free counting pass of 100 count requests, and up to the declared number of billed generations.
2. **Vertex Sonnet.** The same with the version 3 template and prices for `claude-sonnet-5-5` (roughly $5 reserved for 3 replicates at $2 and $10 per million). Sonnet access was verified by the first pass. Use a new output directory and labels path; the first pass's run directory belongs to its version 1 declaration and `vertex-sonnet-v2-r3` to its version 2 declaration.
3. **JevK5 MCP.** Fill the mcpme executable SHA-256 (`shasum -a 256` of the command's first element) and a request limit of at least 300. Decide whether the 24,000-character estimate bound is acceptable, knowing it leaves at most 19 items with JevK5 sufficiency labels, or authorize a different bound. Authorizing the run authorizes starting the mcpme slot process and up to the declared number of local decisions.
4. **Qwen local.** Fill a request limit of at least 300, and make sure the selected Qwen model is the one loaded in mlx-serve on port 11234. Authorizing the run authorizes up to the declared number of local generation requests.
5. **Hosted Jev.** Out of the runner's scope. Move the key into the Keychain. Approve a plan amendment admitting the provider. Authorize the adapter, its contract and tests, and the data-terms review. Then authorize a declared, capped run.

After labels exist, `score` produces the rates. P4 step 3 then selects the judge or ensemble with the lowest error, and the earlier LongMemEval local labels are annotated with their judge's measured rates. Because the verdict prompt is reference-only, compare runner judges on the reference-only variant and report the grounded variant beside it.

### Unverified without a live call

- Under version 1, neither model reliably replies with a bare `yes`, `no` or JSON object: the first Sonnet pass left 21 of 100 replies unparseable. Version 2 was built to remove that failure, but its `output_config.format` is refused on generation in `llm-train-482420` by organization policy (measured October 9, 2026; the count endpoint accepts it). Version 3 replaces the constraint with an instruction, so reply adherence is again a model behavior rather than a guarantee. Not exercised against the provider:
  - how often Sonnet and Opus follow the version 3 line exactly, how often they wrap the object in a code fence (tolerated and counted) and how often they add prose (recorded `output_off_schema`);
  - that Sonnet with `between_tools` actually emits no thinking tokens on these prompts (the synthetic probe showed only that the request is accepted);
  - that Opus accepts `output_config.effort: "low"` without `format`, and how many thinking tokens it spends at low effort on the long sufficiency prompts, so whether 2,048 output tokens is enough;
  - whether the added system line, or a JSON-wrapped answer, changes verdicts compared with a bare reply to the same upstream prompt;
  - the input tokens the line adds, and so the exact reservations (the counting pass measures them before any generation).
- Opus access and model echo in `llm-train-482420` for these requests. Sonnet access, echo and the accepted omission of `temperature` were verified by the first pass.
- Token counts and therefore cost. Prices are not assumed anywhere in code.
- JevK5 token counts for long sufficiency requests, its behavior on requests near its context limit, and whether its cache makes replicates identical.
- That the running mlx-serve still serves the pinned Qwen model, and Qwen's adherence to the bare-JSON sufficiency reply.
- The real `StdioMCP`, `vertex.post` and loopback transports inside the runner. Their own synthetic contracts pass, and the runner was exercised only with fakes.

## Verification

- `python3 scripts/test_judge_calibration.py`: 29 synthetic contracts, all passing. One was added on October 9, 2026 for the decline-rule reversal. It covers `merge-regrade`:
  - the subset-to-source mapping through `source_item_id`, and only verdict, sufficiency, faithful and a non-empty note applied;
  - an empty re-grade note keeping the earlier note, and the reveal record and unsupported flag unchanged;
  - the base's `derived` block not copied, and a revision block with the base hash, the reference-agreement rubric, the `regrade` record and one change per changed item, verified by `score --original-adjudications`;
  - refusal of a mismatched set ID or items hash, an incomplete or partial re-grade, a re-grade with its own revision block, a re-grade that changes nothing, a key naming another set, a remapped, duplicate or unknown source item, and a tampered subset item;
  - the CLI writing a 0600 file, printing no note text, and refusing an existing destination.

  With the same change, the helper formerly named for the evidence-relative set was renamed `_withdrawn_rule_set`. The code's descriptions now present the reference-agreement target as the rule, and the combined rule as history.

  Three were added earlier on October 9, 2026 for the decline-rule change, which was later withdrawn:
  - the derived reference target: derivation from a v2 export (hash, listed flips, revision block not copied), provenance verified against the source, refusal of unknown, abstention, not-accepted and duplicate items while deriving, and the fixed codes for a changed source hash, an unlisted verdict, note or sufficiency change, a target mismatch, an invalid or extra change field, a duplicate or unknown item, an abstention item, a `revision` block, an invalid block and a v1 file; the CLI writes a 0600 file, prints IDs and hashes only and refuses an existing destination; `score` reports the derivation;
  - the lexical decline classifier equal to `answer_presentation_replay.decline_outcome` (including the 200-character boundary and a typographic apostrophe), and the combined rule: rule accepts only for a lexical decline with gold not delivered whole, abstention left to the judge, a judge tie left `unknown`, the `lexical-with-partial` mode, disagreement IDs, the labels hash, an invalid mode refused, and no answer or note text in the output;
  - `pool-scores`: summed counts and recomputed Wilson intervals over two sets, `set_id:item_id` disagreements, and refusal of a duplicate set, a variant missing from one report and a foreign format.

  Four were added earlier on October 9, 2026:
  - the self-correction heuristic's two signals and its guards: no signal for abstention questions, for a consistent headline, for a headline of the wrong kind, for a single paragraph, or for "latest correction" and apology phrasing;
  - extension strata and assembly: base-set answers excluded, quotas, at most 3 self-correction items per question and at most 2 per question and run family, the `jx-` set ID, the signals in the key, private modes, a clean blinding check, the `self_correction_shortfall` and `extension_below_minimum` refusals with nothing written, and default selection unchanged;
  - replay candidates: answer digest, evidence verified from byte ranges, gold delivery from `measure.json`, an incomplete attempt ineligible, and the default judge's strict majority as a prior label (a tie with an unparseable reply gives none);
  - `subset`: items copied unchanged under new opaque IDs, private modes, and refusal of duplicate, missing and tampered source items.

  Re-assembling the base set with its seed after these changes reproduces its items byte for byte (items SHA-256 `44c998ea…f833`). Its key hash changes only because the key embeds the prior-judge table, which gained `vertex-sonnet-default-qa`. The earlier 21 contracts cover:
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
  - the version 2 and version 3 Vertex declaration templates of both models and their checks;
  - native byte-range resolution with digest verification;
  - v1 and v2 adjudication loading, refusal of an invalid faithful value, of faithful or a revision block in a v1 file, and of an unknown format;
  - revision consistency against the original export: hash, unlisted changes (verdict, faithful, note text, reveal record), listed changes that did not happen, source and target mismatches, malformed, unknown and duplicate entries, and the CLI's fixed error code;
  - faithful counts, breakdowns and cross-tab, identical judge rates when only faithful changes, a revision's sufficiency change not counted as a change after reveal, and no note or rubric text in the score output;
  - the form's faithful field inside the post-reveal block, the decline rule text, v2 export, v1 and v2 import, and the `form` regeneration command (private modes, no overwrite, items hash check).
- `python3 scripts/test_judge_calibration_run.py`: 31 synthetic contracts with fake transports for all four judges, all passing. Four were added on October 9, 2026 for prompt set v4. They check:
  - the v4 and rubric hashes, pinned in code and in the v4 template;
  - that prompt set v4 is prompt set v3 plus the rubric component only, and that the v4 template differs from v3 only in format, status and prompts;
  - the sentence inserted once at the rubric boundary, with every other byte unchanged, and refused without the boundary;
  - v4 request bodies equal to v3's except for the sentence, sufficiency bodies identical, and v3, v2 and local requests unchanged and without it;
  - a network-free dry run, and a fake verdict-only run that records prompt set v4 and the rubric hash in the labels;
  - the v4 `check-declaration` refusals.

  One was added on October 9, 2026 for verdict-only declarations: only `["sufficiency", "verdict"]` and `["verdict"]` pass `check-declaration`, limits are checked against the verdict-only plan, the verdict request and count bodies equal those of the full plan, the dry run makes no call, and a fake run sends verdict requests only and leaves sufficiency unlabelled. Four were added on October 9, 2026 for version 3: prompt set v3 and reply-instruction hashes pinned in code and in the v3 templates, the exact line texts, the v2 component hashes unchanged, and a changed line refused (`prompt_hash` and `reply_format_hash`) for v3 but not v2; request and count bodies per model (no `output_config.format`, Sonnet `between_tools` without `output_config`, Opus `output_config` `{effort: "low"}` without `thinking`, the line as the verdict `system` and appended to the sufficiency system text, user messages identical to v2, no sampling keys) and a network-free dry run; strict instructed parsing (bare and fenced JSON accepted; prose, prose plus JSON, JSON plus prose, two objects, a non-`json` fence, an inline fence, extra keys, wrong or differently cased enum values, non-string values, duplicate keys and the other stage's object refused), the fixed codes through a full fake run, `reply_wrapper` receipts and wrapper counts, `reply_format` and prompt set v3 in the run record and labels, and re-authentication that refuses the v2 parser; and the v3 `check-declaration` rules (`structured_outputs_forbidden`, `reply_format_hash`, `prompt_hash`, the shared thinking, effort and output-cap rules, v1 and v2 still valid, the CLI exit code). Five were added on October 9, 2026 for version 2: the reply schema hash pinned in code and templates and separate from the prompt hashes; request and count bodies per model (`thinking` and `output_config` fields, no sampling keys, version 1 bodies unchanged) and the dry run's reported fields; strict structured parsing with the fixed codes `output_off_schema`, `response_incomplete` (including a thinking-only truncated reply), `refusal` and `model_identity_mismatch`, receipts carrying stop reason and thinking tokens, and re-authentication of those captures; version 1 declarations keeping bare-text parsing and resume; and `check-declaration` refusing disabled or budgeted thinking, `between_tools` above effort `high` or on Opus, an implicit Opus effort, out-of-range output caps and a schema hash mismatch, with the adapter refusing the same combinations. The earlier 17 cover:
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
