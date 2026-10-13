# Retrieval variants: passages, role-weighted scoring and feedback expansion

Record date: October 13, 2026. Item 2 of the accuracy batch the user mandated on October 13 (reader fixed to hosted Gemini 3.8 Flash; see [STATUS.md](STATUS.md) section 8). Three retrieval changes to the `exchange_packed` default were built as explicit, versioned policies and measured offline on the P1 harness before any paid answer. Each section states whether it reports implemented behavior, measured results, inferences or decisions.

## Why these three (inferred from the October 12 records)

The [evidence-allowance record](EVIDENCE-ALLOWANCE.md) closed the budget lever: on the development cohort the remaining 26 missed gold turns under `exchange_packed` are 12 that never become candidates and about 10 candidate leads at block ranks 19 to 33, one to three pages long, skipped by the token budget. The mandate named three attacks on that shape:

- **Passage units for long turns.** If a long turn costs a third of its whole pages, the budget reaches further down the ranking.
- **Role-asymmetric scoring.** The annotated turns are leads (user turns) in 11 of 14 candidate misses; a block whose question terms sit in the user turn should outrank one whose terms sit only in the assistant reply.
- **Pseudo-relevance feedback.** The 12 never-candidate turns share no question term with their block; terms from the top matched blocks might reach them.

## Implemented

Four explicit component policies in `Sources/Boros/EpisodeBudget.swift`, each `selectedQwenExchange` with its own version string, `exchange_packed`'s caps (12,000 evidence tokens, 48 spans), window (32 blocks), audits and value-density packer. None is a default; `currentSelectedQwen` remains `exchange_packed`.

| Policy | Version | Harness arm | What changes |
|---|---|---|---|
| `selectedQwenExchangePassages` | `…-v3-exchange-passages` | `exchange_passages` | A source over `passageSourceThresholdBytes` (1,280 bytes, about 400 tokens) is delivered as a head window of about `passageHeadBytes` (256) plus up to `passageWindowsPerSource` (2) query-centred windows of about `passageWindowBytes` (800, about 250 tokens) instead of whole pages (`ExchangeBlockQuery.passages`). Windows are the spans holding the most query-term word hits, chosen greedily, snapped outward to whitespace within 64 bytes, merged when they overlap, never splitting a scalar; each is the exact bytes of the source at its offset, which the assembler re-reads. A source with no hit delivers its head only. |
| `selectedQwenExchangeRoles` | `…-v3-exchange-roles` | `exchange_roles` | Each matched term's contribution to a block's score is scaled by its user-turn share: a hit in an assistant turn counts `assistantTermWeight` (0.5) of a hit in a user turn (`ExchangeBlockQuery.rankWeighted` with a per-block, per-term share). An assistant-only match still ranks, at half weight. Scoring version `idf-term-coverage-sqrt-byte-cost-roles-v1`. |
| `selectedQwenExchangeFeedback` | `…-v3-exchange-prf` | `exchange_prf` | After the plain ranking, up to `feedbackTermLimit` (5) terms of the top `feedbackBlocks` (3) blocks join the query at `feedbackTermWeight` (0.3): terms that are not query terms, have at least 3 characters, are not all digits and occur in at least `feedbackMinimumBlocks` (2) of those blocks, ordered by block count times IDF, then term. A block matching only an expansion term becomes a candidate. The audit records the term count and a digest of the terms. Scoring version `…-prf-v1`. |
| `selectedQwenExchangeRolesFeedback` | `…-v3-exchange-roles-prf` | `exchange_roles_prf` | The roles scoring, then feedback terms from its top blocks, re-ranked under the same role weights. |

Every parameter above was committed before the development-cohort measurement and none changed afterward.

The two scoring variants read per-role and whole-vocabulary block statistics that the persistent exchange sidecar does not store (its postings hold one count per block and term), so they rank over the per-turn in-memory rebuild: `ContextComponentPolicy.requiresInMemoryRanking` routes `ExchangeBlockQuery.select` to the rebuild whatever the diagnostic index source, and the audit's `index` label and `scoring_version` record it. The shared scoring function `rank` is unchanged, so the persistent index and the rebuild stay bit-identical for every other policy; `rankWeighted` is a separate function with unit weights and no share computing the same quantity. The passages variant is packer-only and runs over either corpus.

### Contracts

- `--retrieval-strategy-self-test` (`ExchangeBlockQueryChecks.swift`): the four policies are explicit, versioned, distinct, keep `exchange_packed`'s caps and window and name their modes; role weighting ranks a user-turn match above an equal-byte assistant-turn match at exactly half its score and keeps the assistant-only match; feedback picks the shared non-query terms of the top blocks at weight 0.3 and ranks a block that matches only an expansion term; a long source yields a head plus a query-centred window of exact bytes under the page limit, a short source stays whole, a source without hits delivers its head; the packer admits the windows of a long reply at a budget that refuses it whole.
- `--retrieval-strategy-integration-test` (`ExchangeEpisodeChecks.swift`): the four policies join the per-policy journal suite (actual preparation under the synthetic tokenizer, admission, journal and archive validation).
- `scripts/test_retrieval_harness.py`: the passage-aware measure below and the arm list.

### Harness additions

`scripts/retrieval_harness.py` gains the four arms, `--arms` (run a subset of arms; the report records `run_arms`), and a passage-aware delivery measure beside R2, because R2 counts whole turns and a windowed turn is partial by construction:

- **R2p (`r2p_answer_delivered_recall`).** Every annotated positive turn is delivered whole or, when the reference answer string occurs literally in the turn (lower-cased, whitespace runs collapsed), some delivered byte range of that turn contains an occurrence. A turn without the answer string keeps the whole-turn test, so R2p is at least R2 by construction. `turn_answer_string_in_turn` reports how many positive turns the string test can apply to. The answer is read by the scorer only; the selection process never receives it. This is the defensible measure the data offers: LongMemEval annotates turns, not spans.

## Measured, offline (P1 harness)

Conditions: this checkout's sources compiled into the delivery harness, pinned offline tokenizer, three workers, one replicate, the stores built by earlier runs reused (the ingestion sources are unchanged). Reports, metadata only, under `.build/evaluation/` of this worktree: `variants-regression-1.json`, `variants-development-1.json`, `variants-regression-2.json`, `variants-development-2.json`.

### Regression cohort (12 answerable of 14)

| Arm | R1 | R2 | R2p | Turns whole / 18 | Prompt tokens p50 / p95 |
|---|---:|---:|---:|---:|---:|
| `exchange_packed` | 12 | 11 | 11 | 17 | 14,335 / 16,942 |
| `exchange_passages` | 12 | 11 | 11 | 17 | 14,888 / 17,636 |
| `exchange_roles` | 12 | 11 | 11 | 17 | 14,272 / 17,200 |
| `exchange_prf` | 12 | 10 | 10 | 16 | 14,165 / 16,762 |
| `exchange_roles_prf` | 12 | 11 | 11 | 17 | 14,310 / 17,044 |

- The assistant-recall guard holds: `1b9b7252` and `4baee567` (gold is the top block's reply) are delivered under every arm. Under `exchange_roles` the `4baee567` block drops from rank 0 to rank 2 and is still delivered.
- `exchange_prf` loses `1192316e` (multi-session): its rank-13 lead falls to the token budget (`T`) after expansion terms promote other blocks. That is the drift the mandate said to watch for.
- The known miss `1a1907b4` stays missed under every arm (its next-neighbor unit stays `T`).

### Development cohort (90 answerable of 100)

| Arm | R1 | R2 | R2p | Turns whole / 165 | Answer-string turns covered | Wins / losses on R2 against `exchange_packed` | Prompt tokens p50 / p95 |
|---|---:|---:|---:|---:|---:|---|---:|
| `exchange_packed` | 78 | 69 (76.7%) | 69 | 137 | 137 | | 15,522 / 17,297 |
| `exchange_passages` | 78 | 64 (71.1%) | 66 | 133 | 135 | 0 / 5 | 15,688 / 17,506 |
| `exchange_roles` | 78 | 72 (80.0%) | 72 | 142 | 142 | 4 / 1 | 15,551 / 17,209 |
| `exchange_prf` | 79 | 72 (80.0%) | 72 | 139 | 139 | 3 / 0 | 15,570 / 17,299 |
| `exchange_roles_prf` | 79 | 74 (82.2%) | 74 | 143 | 143 | 6 / 1 | 15,567 / 17,276 |

By category, R2 (`exchange_packed` / roles / prf): knowledge-update 13 / 13 / 13 of 14, multi-session 11 / 12 / 13 of 23, assistant recall 11 / 11 / 11 of 11, preference 4 / 4 / 4 of 5, user recall 12 / 12 / 12 of 12, temporal 18 / 20 / 19 of 25.

The answer string occurs literally in 38 of the 165 positive turns, so R2p can relax R2 on at most 23 percent of turns; on the other 77 percent it is R2.

What each variant did:

- **Passages lose.** Five cases lose R2 (four assistant-recall, one user-recall): their long gold turns are now windowed, and in three of the five the turn does not contain the answer string at all, so even R2p counts them lost; the two that do contain it are covered (R2p 66). The freed budget admitted more units (candidate leads skipped by the budget fell from 12 to 9) but none of them was a gold turn, so there is no win. Prompt size did not fall: the packer fills the same cap with more spans.
- **Roles gain.** Four wins, one loss, net +3 (R2 69 to 72). The wins are budget-skipped leads that now rank high enough to be packed: `9a707b82` (temporal; rank 26 to 10), `73d42213` (multi-session; 18 to 7), `gpt4_ec93e27f` (temporal; 24 to 12) and `129d1232` (multi-session; 19 to 15). The loss is `gpt4_d12ceb0e` (multi-session): one of its three gold leads stays at rank 11 but the budget now runs out before it. Candidate leads skipped by the budget fell from 12 to 7.
- **Feedback gains on development and drifts on regression.** Three wins, no loss on development (`73d42213`, `6e984302`, `ba358f49`; the last is one of the never-candidate turns, now a rank-9 lead), one regression case lost. Of the 16 never-candidate gold turns the expansion reached one; the other wins are candidates that moved up.

### The combined arm

`exchange_roles_prf` (the second development run, `variants-development-2.json`, which reproduced the three single arms case for case) wins six cases and loses one against `exchange_packed`: R2 69 to 74 of 90 (76.7 to 82.2 percent), turns whole 137 to 143 of 165, R1 78 to 79. The wins are the four roles wins plus `gpt4_e05b82a6` (multi-session; a rank-28 lead now at rank 10) and `ba358f49` (the never-candidate turn feedback reaches); the loss is the roles loss `gpt4_d12ceb0e`. By category R2 is knowledge-update 13 of 14, multi-session 14 of 23 (from 11), assistant recall 11 of 11, preference 4 of 5, user recall 12 of 12 and temporal 20 of 25 (from 18). Candidate leads skipped by the budget fell from 12 to 8 and never-candidate gold turns from 16 to 14. On the regression cohort it changes no case (R2 11 of 12): the role weights remove the feedback drift that cost `1192316e`, and both assistant-recall cases stay delivered. Prompt size is unchanged at the median (15,567 against 15,501 tokens).

## Decision (gate for paid answers)

The mandate's gate: answer only an arm that clears a meaningful offline gain without losing cases. `exchange_passages` fails it (no win, five losses) and is dropped. `exchange_prf` alone fails it (a regression loss). `exchange_roles` alone is net +3 with one loss. `exchange_roles_prf` is net +5 with one loss on development and no change on regression, recovers four of the twelve budget-skipped leads and two of the sixteen never-candidate turns, and keeps the assistant-recall guard; it is the one arm answered. The paired Gemini run on the 73 step 3 inputs generates only the questions whose request differs from `exchange_packed`'s (item 1a); its declaration and result are recorded in [PRESENTATION-PROBES.md](PRESENTATION-PROBES.md)'s companion section below.

## Step 3 inputs: capture and the paired run that was not dispatched (measured, offline; decision)

`scripts/exchange_packed_answers.py capture` rebuilt the exact answer request bodies of `exchange_packed`, `exchange_roles` and `exchange_roles_prf` for the 73 step 3 inputs (`.build/retrieval-roles-20261013/captures.json`, SHA-256 `3c59f837…68b7`; the baseline reproduced the October 12 capture's delivery and gold class on 73 of 73). Gold delivery on the 73 inputs, whole / partial / none / no gold turns:

| Arm | Whole | Partial | None | No gold turns | Prompt tokens median |
|---|---:|---:|---:|---:|---:|
| `exchange_packed` | 53 | 9 | 8 | 3 | 15,414 |
| `exchange_roles` | 58 | 4 | 8 | 3 | 15,513 |
| `exchange_roles_prf` | 58 | 4 | 8 | 3 | 15,441 |

Under `exchange_roles_prf`, four partial deliveries and one none became whole, and one partial became none; 52 questions keep whole delivery with a different surrounding context. That is the same shape as the development result (more budget-skipped leads reached), on inputs that were not used to choose the parameters.

The unchanged-request rule (item 1a) found nothing to reuse: the request body differs from the baseline's on 73 of 73 inputs, and the set of delivered byte ranges differs on 72, because role weighting re-ranks blocks and the packer admits different units, not merely the same units in another order. An order-only change would not have been a tie by construction either, and the driver does not treat it as one. The paired run is therefore the full one: 438 answers at about $10.8 at the declared standard rate plus about $1.5 of judging. With $16.54 spent on the presentation-probe answers and about $2.2 on their judge, that would end near $31 against the $25 the mandate allows without asking. **No retrieval answer was generated.** The arm stays an explicit, selectable policy; `currentSelectedQwen` remains `exchange_packed`.

**Update, later on October 13:** the coordinator funded that run; its result is in [FOUR-ARM-PAIRED-RUN.md](FOUR-ARM-PAIRED-RUN.md): D -0.9 points (interval -8.3 to +6.0), the five newly whole questions +40 points and the 66 re-contexted questions -2.5; not promoted.

What a decision would have needed (as proposed before that run): the full paired run above under the declared rule (promote at D >= +5, lower bound >= -2, no cohort below -5), with the capture already made; the October 12 record measured that newly whole delivery converted at 17.9 to 76.9 percent accepted for this reader, so the five recovered questions could be worth about +4 to +5 points on the 72, while the 52 re-contexted questions carry the risk.

## Privacy and artifacts

The harness reports contain identifiers, counts and timings, never source text, questions or answers. No model call was made for this record's offline section.

## Reproduce

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/retrieval_harness.py --cohort regression --workers 3 --arms exchange_packed exchange_passages exchange_roles exchange_prf --output .build/evaluation/variants-regression-1.json
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/retrieval_harness.py --cohort development --workers 3 --arms exchange_packed exchange_passages exchange_roles exchange_prf --output .build/evaluation/variants-development-1.json
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/retrieval_harness.py --cohort development --workers 3 --arms exchange_packed exchange_roles exchange_prf exchange_roles_prf --output .build/evaluation/variants-development-2.json
```
