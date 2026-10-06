# Independent LongMemEval development cohort

This comparison extends the [seven-case development adapter](LONGMEMEVAL.md) with fourteen new cases from the same pinned LongMemEval S artifact. It measures ordinary recent-only and hybrid answering through the shared counted coordinator. Current verification and execution status belong in [STATUS.md](STATUS.md).

## Selection and independence

The source revision remains `98d7416c24c778c2fee6e6f3006e7a073259d48f`, with 500 records, 277,383,467 bytes and SHA-256 `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`.

The selector excludes the seven earlier cases and their complete session inventories. Slots contain two cases for each of the six original answerable categories, followed by two abstention cases retaining their original category labels. Within each slot, candidates rank by SHA-256 of the UTF-8 bytes of `boros-independent-longmemeval-development-v1`, a NUL separator and the original question ID. Ties use the original ID. The first eligible candidate fills the slot.

Eligibility requires no session-ID overlap, no exact whole-session role/content digest overlap and no exact question-byte digest overlap with any excluded or previously selected case. Session hashing preserves complete original role/content order and ignores scorer annotations. Duplicate session IDs or session payloads within a selected case are refused. Answers and positive-turn annotations do not influence ranking or eligibility. The selected IDs and native projection hashes are frozen in `scripts/longmemeval_independent_cases.py`.

The fourteen histories contain 662 sessions, 6,841 original messages and 6,872,207 UTF-8 source bytes. The earlier cohort contains 337 distinct session IDs and 337 distinct session payloads. Exact disjointness has been independently reconstructed. Independent authorship, semantic similarity and representativeness remain unestablished. These cases are a new development cohort; they are not a held-out product gate.

## Answering contract

Native input version 7 accepts fourteen separately pinned oracle-free projections and one separate configuration. Original source bytes, array order, role, status, dates, source indices and question dates are preserved. Gold session IDs, positive-turn flags and reference answers stay outside native input and model requests. Each history runs recent-only followed by hybrid, with replicate zero and separate restored stores. Version 7 uses the original question for lexical and semantic retrieval, matching version 5 behavior.

The new comparison freezes a 1,024-token output cap before model execution. Repeated output-limited failures in the earlier development runs motivate this setting. Both arms use the same cap. The Qwen model, System instructions, seed, temperature, thinking setting, context and evidence limits retain their existing values. The normalized native configuration hash is `59dee690589e35b394ea40b6adfbf4bde36aacb349912abb0e94a09aebbefe07`. Versions 1–6 and the earlier 512-token results retain their original contracts. Differences across cohorts and output caps do not establish a causal improvement.

The fresh CLI requires a matching terminally verified prebuilt binary. Before provider work, it durably declares all 28 attempts, selected cases, complete selection manifest, source/projection/scorer/configuration pins and implementation hashes. Code and binary identity are checked before and after execution. Each arm exports fourteen ordered two-field hypothesis records privately; failed attempts export empty hypotheses and retain their denominator. Public reports contain counts, statuses, usage metadata and hashes. Report and hypotheses paths must be fresh and separate, outside tracked source, with caller-created symlink destinations refused. Standard macOS temporary-directory aliases resolve to their canonical system paths.

```sh
python3 scripts/evaluate_longmemeval_independent.py --execute \
  --source /absolute/path/pinned/longmemeval_s_cleaned.json \
  --output /absolute/path/new-independent-report.json \
  --hypotheses-directory /absolute/path/new-private-independent-hypotheses \
  --binary /absolute/path/verified/Boros.app/Contents/MacOS/Boros \
  --binary-verification /absolute/path/terminal-native-verification.json
```

## Grading and limits

The earlier fourteen-attempt grader retains its original contract. A separate 28-attempt local QA adapter binds this cohort's source, selection manifest, report, exports and native verification before judging operationally complete answers. Complete gold-source delivery is measured independently of answer completion; incomplete retrieval does not exclude an otherwise complete answer from grading. Failed answers receive no call or credit. Private requests and responses are required, and every eligible call must preserve the declared input and dependency hashes.

```sh
python3 scripts/local_longmemeval_independent_qa.py --execute \
  --source /absolute/path/pinned/longmemeval_s_cleaned.json \
  --answer-report /absolute/path/independent-report.json \
  --answer-report-sha256 EXACT_ANSWER_REPORT_SHA256 \
  --hypotheses-directory /absolute/path/private-independent-hypotheses \
  --binary-verification /absolute/path/terminal-native-verification.json \
  --protocol /absolute/path/pinned/evaluate_qa.py \
  --controls-report /absolute/path/validated-synthetic-controls/report.json \
  --controls-report-sha256 EXACT_CONTROLS_REPORT_SHA256 \
  --output-directory /absolute/path/new-independent-qa \
  --private-directory /absolute/path/new-private-independent-qa
```

The grader requires matching fourteen synthetic controls for the unchanged shared judge, freezes its own dependency inventory separately, and predeclares all 28 request hashes and eligibility statuses. Private files use `0600` inside `0700` directories. The loopback transport refuses proxies and redirects and keeps the strict ten-token yes/no judgment contract. Input or dependency drift before or during a call prevents credit. Judge resource usage is separate from Boros answering episode charges.

The local answerer and judge use the same Qwen model and unchanged upstream grading templates. Synthetic controls do not establish independent real-answer judge calibration. Official QA, representative quality, controlled cache effects, replicate variance and workload economics remain unfinished. Native journal integrity relies on the matching native verification and post-terminal checks; sanitized opaque admission-context digests cannot replay cleaned temporary journals. One fixed-order development comparison cannot establish a release gate.
