# Sufficient-evidence answering control

Status: implemented and executed development control, October 6, 2026. This supplements the paired [developer-history diagnostic](DEVELOPER-ANSWER-EVALUATION.md). It does not change its inputs, rubrics, denominators or retained reports.

## Purpose

The range-aware retrieval repeat delivered every required span, but five hybrid tasks still failed. Run the same nine answerable questions with curated complete original exchanges to measure reproduction and citation when the host has supplied the annotated evidence. Absence probes require their corpus context and are excluded from this separate control.

Each pack contains the complete original human anchor and its actual following assistant message. A cross-message pack contains both pairs in original chronological order. The human anchor identifies the requested reply; the complete assistant message preserves its first nonempty line and the surrounding source. The pack rationale and all source/projection/oracle hashes are frozen before provider work. Expected answers and rubrics remain on the Python scorer side.

| Original history | Historical pack | Cross-message pack | Later-source pack |
|---|---:|---:|---:|
| h00 | 2 events / 2,189 bytes | 4 events / 4,105 bytes | 2 events / 1,133 bytes |
| h01 | 2 events / 2,013 bytes | 4 events / 2,379 bytes | 2 events / 2,095 bytes |
| h02 | 2 events / 2,048 bytes | 4 events / 3,690 bytes | 2 events / 458 bytes |

Retain original IDs, full text, role, capture status, scope and ordering. Store each pack in its own disposable store. Do not reconstruct gold lines or add rubric fields to the native input. Imported generation completeness and original timestamps retain the developer diagnostic's limitations.

## Execution contract

The native input uses version 2 with nine exact oracle-free projection pins. Existing version-1 paired input pins remain immutable and reject these packs. Each control document has one `recent_only` attempt with replicate zero and the original question. The host uses the existing acceptance, restored-store, preparation, count/admission, v3 original-input receipt, dispatch, durable streaming and finalization path.

Generation settings, host instructions and episode/component caps match the developer diagnostic, including the 2,048-token output reserve. The Python configuration digest is `62381f748b563189b34b9c97f637c3ee234aef7095ce64096ecf6411ece850cf`. Foundation's canonical representation uses `0` for Python's `0.0`; its separately enforced digest is `73729124226e2a729d052ea49d6f03ecced31b2b93e3beea63064ab046fa0013`. These are distinct serializations of the same frozen values.

Before disposal, validate the actual invocation, request/preparation linkage, version-3 source/body/count receipt and original source ranges. Verify the entire declared pack, including human anchors and all assistant bytes. Merely delivering the gold line does not satisfy this contract. No invocation or no valid receipt leaves the conditional result unavailable. A valid receipt with reduced pack content records `witness_pack_not_delivered`.

## Scoring and limits

Retain all nine declared attempts, including setup, admission, transport, capture and reduction failures. Apply the original exact-answer/citation rubric after terminalization. Report overall control success separately from success conditional on operational completion, complete pack delivery and validated source/body/count provenance. Missing conditional evidence is unknown, rather than a model failure or a successful feasibility result.

Retain the original rubric task score separately. A correct answer with an incomplete or unvalidated pack cannot count as a verified control success. Overall verified control success uses all nine declared attempts; conditional success uses only eligible attempts.

Source text, questions, answers and expected values remain absent from reports. Retain counts, hashes, fixed failure codes, delivered source ranges, component counts, observed provider identity and charged/held/unknown resources. Compile from an immutable captured implementation. Each report uses a new destination; no retries replace failures.

Witness validation and scorer inspection are post-terminal diagnostic work outside the episode's runtime charges. Record their timings separately. Runtime resource counters do not establish total experiment cost or physical I/O.

This control measures curated reproduction and citation on reused development questions. It does not establish independent-author coverage, natural-question recall, representative quality or general over-cap feasibility. A control that fits the recent component demonstrates only that declared pack's measured delivery. A broader feasibility oracle still needs funded whole-render measurement for witnesses that exceed component allocations, without issuing an admission grant.

## Commands

```sh
python3 scripts/test_evidence_controls.py
python3 scripts/evaluate_evidence_controls.py \
  --source .build/public-sources/devgpt-20230727-pr.json \
  --output .build/evaluation/devgpt-evidence-control-20261006.json
```

Run the live command only after native input/provenance contracts, controlled transport checks and the matching-source application suite pass. Use a new output destination for each execution.

## Recorded execution

The matching optimized app passed **3,214 checks** with a frozen **131-file** source capture and strict deep signature verification. The suite includes 23 answering checks and 19 evidence-control checks, covering input pins, complete/reduced delivery, Stop, provenance tampering, failed-attempt denominators and private fixture cleanup. A preliminary wave left its final synthetic fixture at process exit; callback-release sequencing and an explicit cleanup assertion corrected it. The final wave left zero fixture directories.

All **9/9** live Qwen attempts completed. Every complete pack reached the actual counted request and passed version-3 source/body/count revalidation. All nine were conditionally eligible. Both overall verified control success and conditional task success were **5/9**: single quotes passed 5/6, cross-message tasks 0/3. Three cross-message failures were `response_top_level` (parsed JSON root was not an object); the precise root type was not retained. The h02 historical quote failed exact-answer scoring.

The original source, projection/oracle, configuration and system pins match the preceding paired diagnostic. All 90 runner implementation hashes match the verified capture. The declaration was observed before compilation or input creation and matches the final report: SHA-256 `99ae1124ae3bc7b5da6625bf86abd07503b65673395993c7dcd617f684d3779c`.

Report: `.build/evaluation/devgpt-evidence-control-20261006.json`, 307,748 bytes, SHA-256 `7d9352a85048b9a5e2e7fef0ce2efa5904660c409127ab4519daebc70295676c`. Verification: `.build/evaluation/evidence-control-final-verification-20261006.json`; app: `.build/boros-evidence-control-final/Boros.app`. Runtime stores and answer IPC were discarded. These reused one-replicate development questions establish evidence-present failures on the curated packs. Response-format reliability and independently frozen natural-question testing remain next; representative quality and general over-cap feasibility remain open.

## JSON output instruction amendment

The separately declared `json-output-instructions-v1` amendment changes only the System instruction: follow the user's requested output structure and emit requested JSON without Markdown or explanatory prose. It supplies no expected answers, citation IDs or rubric fields. Original questions, complete packs, source/projection/oracle pins, generation settings, output reserve, component/episode limits and single-replicate order remain frozen.

The Python configuration pin is `2b1535b93ea3bbb16035bbe3f744b6e4c980eac9837ea8694925fc5554d37e69`; the Foundation representation pin is `f13e87eb29ce2ecf88746293d3f01d74841394dc0a0aca3d2e9d5747dda53361`. Native version-2 inputs accept these exact settings as a separate allowlisted amendment. Their report retains the actual configuration digest, and conditional eligibility requires that digest as well as the original input/source/body/count proof. The CLI defaults to the original control. Each amended run labels its declaration and report before execution and uses a new destination.

Run `scripts/evaluate_evidence_controls.py` with the same pinned source, `--format-instructions` and a new output such as `.build/evaluation/devgpt-format-instructions-20261006.json`.

The matching optimized app passed **3,219 checks**, with the same 131-file capture boundary and strict deep signature verification. All nine live attempts completed with their entire packs delivered and their source/body/count proofs validated. Overall and conditional task success remained **5/9**: 5/6 single quotes and 0/3 cross-message tasks. The same h02 historical quote failed exact-answer scoring. Two cross-message responses failed top-level-object validation; the third failed JSON syntax. No improvement is established, and application defaults and explicitly saved instructions remain unchanged.

The declaration was observed before compilation or input creation and matches the final report: SHA-256 `15f092be1f3d55fc3da6f402fcc29cec3622ae05b27715e0630bc980ea330913`. All nine original pack annotations and all 90 runner source hashes match their frozen inputs. Report: `.build/evaluation/devgpt-format-instructions-20261006.json`, **307,987 bytes**, SHA-256 `4e91abb620a10e83b3c4db7fb18f7bfcdbcd5e2fb813013e5f73abb0abe7fdbd`. Verification: `.build/evaluation/format-instructions-verification-20261006.json`; app: `.build/boros-format-instructions/Boros.app`. Runtime stores and answer IPC were discarded. This report remains separate from the original control.

## Provider response-format capability probe

The running local server advertises `json_schema`. Three direct synthetic nonstreaming probes returned HTTP 200: ordinary output matched the requested plain synthetic word, JSON-object mode returned an object, and schema mode matched the fixed synthetic schema. Identical messages had different provider-reported prompt counts: **23**, **60**, and **84** tokens respectively. The active chat template still matches the existing 8,952-byte template pin. This is evidence of additional preprocessing outside that template. The tagged server source identifies its transformation; Boros has not yet implemented or verified the corresponding renderer.

Record: `.build/evaluation/provider-response-format-probe-20261006.json`. These direct capability probes are outside Boros admission/accounting and establish no production-path support. Actual prompts and outputs were not retained in the report. Boros must verify the response-format preprocessing, count its complete rendered input, preserve source/body provenance, and test the shared path before enabling this capability. The failed instruction-only amendment provides no basis for changing the default prompt.

The [official server source at v26.10.1](https://github.com/ddalcu/mlx-serve/blob/02bee553f48cd3bc7d82aba0f8073820bd924738/src/server.zig#L8684) explains the added input. It drops exactly empty messages before format processing, then appends a fixed JSON instruction to the first retained System message or inserts a new System message. Template trimming follows that transformation; whitespace-only and empty System messages therefore differ. `/tokenize` accepts already-rendered raw content and does not perform this transformation. An initial integration can support only the fixed JSON-object mode, attribute added text to mandatory context, retain ordinary receipts byte-for-byte, and reject other formats until their own contracts exist. The server may fall back to prompt-only operation if grammar initialization fails; output validity must remain a measured result. The installed binary advertises the same version and active template, but source inspection alone does not prove all request behavior; matching controlled and live count/admission checks remain required.
