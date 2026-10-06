# Local QA for complete-source controls

`scripts/local_longmemeval_source_control_qa.py` grades the six separately declared [LongMemEval complete-source controls](LONGMEMEVAL-SOURCE-CONTROLS.md). The original fourteen-attempt recent/hybrid grader retains its own contract. Both use the unchanged upstream templates and the same strict local judge implementation. Current verification and execution results belong in [STATUS.md](STATUS.md).

## Inputs and provenance

Execution requires the exact pinned dataset and protocol, the six-control answer report and its SHA-256, its private declaration and ordered hypothesis export, the SHA-bound terminal native verification record, and matching successful synthetic judge controls. The adapter reconstructs the six original case annotations, oracle-free projections and complete original-source inventories before grading. Original questions and scorer answers enter only private judge requests.

Provenance has three stages: native source and binary verification, the historical answering-script inventory recorded before benchmark execution, and the current grader/dependency inventory frozen before judge calls. Adding this grader changes the current script inventory; historical answering inputs remain bound to their recorded build proof. The prebuilt runner's `python_dependencies_captured_before_compile` field is insufficient to establish the current grader's provenance.

The grader validates original UTF-8 ranges, scope, source unions, declared source counts/bytes/ID digest, and available receipt/body/selection hash links. Counted request and native journal integrity rely on the pinned native post-terminal validation. The content-free report preserves an opaque admission-context digest and length; it cannot independently replay the cleaned temporary journal or token-count work.

## Eligibility and denominators

All six declared cases remain in the report. A judge call requires an operationally complete answer, complete declared-source delivery, full-pack eligibility, source/body/count revalidation with proof version 3, matching delivered and declared source counts, and no source-control failure. Full byte delivery leaves semantic sufficiency unknown.

Operational failures, incomplete or unavailable packs, and unverified implementation continuity receive no call or credit. Failed implementation continuity makes all six rows unscored. Judge transport, capture, parsing or identity failures remain unknown judgments. Reports distinguish each reason and show accepted/declared and accepted/scored fractions separately. Failed answering exports must be empty.

The existing fourteen synthetic controls must match the unchanged base grader, upstream protocol, control specification and normalized model settings. The new adapter and imported dependencies have a separate pre-execution fingerprint. Results use the same local Qwen model as answering; held-out judge calibration and runtime/weight attestation remain unestablished.

## Execution

Use absolute paths and fresh, separate output/private directories. Execution publishes a six-row declaration and materializes private requests before calls. Private capture is required. Directories use `0700`; files use `0600`. The loopback transport, redirect/proxy refusal, ten-token output limit, exact yes/no parser and provider usage rules are shared with [the local QA contract](LOCAL-QA.md).

```sh
python3 scripts/local_longmemeval_source_control_qa.py --execute \
  --protocol /absolute/path/pinned/evaluate_qa.py \
  --source /absolute/path/longmemeval_s_cleaned.json \
  --answer-report /absolute/path/source-control-report.json \
  --answer-report-sha256 EXACT_ANSWER_REPORT_SHA256 \
  --hypotheses-directory /absolute/path/private-source-control-hypotheses \
  --binary-verification /absolute/path/terminal-native-verification.json \
  --controls-report /absolute/path/controls/report.json \
  --controls-report-sha256 EXACT_CONTROLS_REPORT_SHA256 \
  --output-directory /absolute/path/new-source-control-qa \
  --private-directory /absolute/path/new-private-source-control-qa
```

These are reused development controls selected from oracle annotations. Their results remain separate from ordinary recall comparisons and official benchmark scores. Judge usage is recorded outside Boros episode accounting. Representative product quality, semantic sufficiency and independent real-answer judge calibration require additional evidence.
