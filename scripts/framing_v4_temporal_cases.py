#!/usr/bin/env python3
"""Temporal-reasoning cohort for the framing V4 variants replay, as opaque runner documents.

The cohort is every answerable ``temporal-reasoning`` question of the frozen development cohort
(``native-investigation-100-v1``, docs/RETRIEVAL-HARNESS.md): 25 questions. Selection reads only the
frozen development selection (question identity and type) and the abstention suffix. The three
temporal abstention questions of that cohort are left out. None of the 25 is in the 21-question
retrieval-on cohort (the development selection excludes the pilot and independent questions).

Histories are built exactly as the existing development runner documents (version 8) are built:
``native_investigation_hundred_cases._history``, the pinned QA projector followed by the version-8
opaque identity projection in its own domain (plan P4 step 4: no answerability cue such as ``_abs``
or the question ID in any model-visible identifier). The only difference from the version-8
document of the same question is the runner document version.

Runner document version 10 has the version-8 shape (one ``hybrid`` attempt, original session dates,
question date) but is answered by the ordinary ``--answer-evaluation`` path, never the native
investigation. Its configuration is the development cohort's (1,024 output tokens). The native
runner accepts only the pinned projection digests in ``PROJECTION_PINS``.

No source text, question, answer or date literal is reported by this module.
"""
from __future__ import annotations

from pathlib import Path

import evaluate_answers as e
import local_longmemeval_qa as qa
import longmemeval_independent_cases as independent
import native_investigation_hundred_cases as hundred

COHORT = "framing-v4-variants-temporal-25"
QUESTION_TYPE = "temporal-reasoning"
VERSION = 10
CONFIGURATION = dict(hundred.CONFIGURATION)
# Public projection SHA-256 (runner document without configuration) per question, as accepted by
# AnswerEvaluationCommand.temporalLongMemoryCorpusProjectionSHA256. Changing one requires a
# matching source amendment there. Order is the development selection's rank order.
PROJECTION_PINS = {
    "gpt4_5438fa52": "f4cd95972ecce6f24f857af29b303bac434f69e1669348037ea415ee8251eb31",
    "gpt4_2d58bcd6": "93a27dac92b54251825e281e2fb087434e9e4eba617e57adffd76fa0ff04cdf4",
    "9a707b82": "634b592990ef122f43de6e97bdb784152388b133469a9888873575e4a8e400bd",
    "gpt4_4929293b": "a18e54765fc3b14f506a6e8d25cc74609f9d8d4799fcb4954bb0a8acb6f65273",
    "0bc8ad93": "1759dc90b775eef36751f9077388bb2e3b9afaf7cca42b49444a5b2401ea3c92",
    "gpt4_e072b769": "e862e2d6e08b17060f1b0913cb5eab3a5e57d98a59200d74530ec2f964b6a5b9",
    "gpt4_d6585ce8": "465b64a525ebe33dfaeb763a07f016a7a6bd77f4b17007aa02951f0d1154ec17",
    "8c18457d": "c2381a25b033fedc0a67df36fc417f0fc1441f17da532bd85b060c54b1a1dada",
    "gpt4_1e4a8aeb": "e128ae013370fb60b02d1a19c3eb273a925a4193a9cf1caee173cbce16d081b2",
    "gpt4_7f6b06db": "4b9dd2a714589cecfd1bf391c750c0f366d808737dfcec613ef9215a02e8debc",
    "4dfccbf8": "65699bbddf8cc222b9b048fab2f8e0c86ee8ab65601193a125093cb604c31651",
    "gpt4_5dcc0aab": "9f619ef25d9edb76b18452bac2e8610f2fff552b17ca3d9168d86dc56913a22d",
    "gpt4_213fd887": "1b7f3cf679b6899f52f900451b37b38dc5cee523ab1101b76074d5fdaa1286c7",
    "6e984302": "5b9564027e5ec0cc5c132fef5a9e01c43fa929fc8e6ef5e8c53e06f1071a8487",
    "gpt4_d9af6064": "879855d61705c849c7476e1758b10d0b8dc8ccd3266d68329e637bf270ef81e6",
    "gpt4_0a05b494": "40eb4291d5616d733af5d2b3fe96464a2d968a9d048f7e412ef6c4a5f8db9f6f",
    "gpt4_7a0daae1": "c5f1e96c743b96106a00b4200390e28febd080f753431a5c8cddbbeb6ae111a8",
    "gpt4_e414231f": "de16110edaa03be42c286050246ad7c4651d31a6d2552556bb99c982ad279238",
    "gpt4_fe651585": "8f1e119f6f59480ced8bb39577927b6f7884392a140b36b94376eba106d8c36f",
    "gpt4_7ddcf75f": "4381759f5a79feec011555d9f238cd272e35a32ee24bb898b6f835832c4adec6",
    "gpt4_ec93e27f": "3285b57320c9703b62b215cb919d4babe11fbd5fd3a2748b1156a199692e6538",
    "gpt4_cd90e484": "4abb425725f9cc9f08cb65afd7e532647a26974c659a0fa57aced30207fb2b84",
    "gpt4_468eb064": "956f83e0df2055fbfc9a4c9d3e6ebf2e1a8770ed5839dd7e33864a89c2c5dd9e",
    "gpt4_f420262c": "26aa41a32a10fc9699b814eb64d14d5e23ed9b8c4bfe41dd0871faa577cce28e",
    "eac54adc": "f33a7b76da76a51778e438d611165d826c8eb2d56f05813ed7bd26633b5cc9d5",
}


def require(condition, code):
    if not condition:
        raise e.EvaluationError(code)


def select(manifest):
    """The answerable temporal-reasoning questions of the frozen development selection, in its order."""
    require(manifest.get("cohort") == hundred.COHORT and len(manifest.get("case_ids") or []) == hundred.COUNT,
            "temporal_development_selection_invalid")
    types = dict(zip(manifest["case_ids"], manifest["case_types"]))
    chosen = tuple(qid for qid in manifest["case_ids"] if types[qid] == QUESTION_TYPE and not qid.endswith("_abs"))
    left_out = tuple(qid for qid in manifest["case_ids"] if types[qid] == QUESTION_TYPE and qid.endswith("_abs"))
    require(bool(chosen), "temporal_selection_empty")
    return chosen, left_out


def runner_input(history, configuration=CONFIGURATION):
    """The version-8 development runner document of the same history, as runner document version 10."""
    require(configuration == CONFIGURATION, "temporal_configuration_changed")
    document = hundred.runner_input(history, hundred.CONFIGURATION)
    require(document["version"] == hundred.VERSION, "temporal_base_version_changed")
    return {**document, "version": VERSION}


def annotation(history):
    document, probe = runner_input(history), history["episodes"][0]
    return {"question_id": probe["question_id"], "history_id": history["id"], "question_type": probe["question_type"],
            "abstention": probe["abstention"], "source_index": history["source_index"],
            "session_count": history["session_count"], "source_count": len(history["events"]),
            "runner_input_sha256": qa.digest(qa.canonical(document)),
            "public_projection_sha256": independent.projection_sha256(document),
            "version_8_projection_sha256": independent.projection_sha256(hundred.runner_input(history)),
            "scorer_annotations_sha256": independent.scorer_annotations_sha256(history)}


def prepare(source, verify_pins=True):
    """(histories, manifest). With ``verify_pins``, every projection must equal its source pin."""
    histories, development = hundred.prepare(Path(source))
    chosen, left_out = select(development)
    by_id = {history["episodes"][0]["question_id"]: history for history in histories}
    selected = [by_id[qid] for qid in chosen]
    require(all(history["episodes"][0]["question_type"] == QUESTION_TYPE and not history["episodes"][0]["abstention"]
                for history in selected), "temporal_selection_type_mismatch")
    annotations = [annotation(history) for history in selected]
    if verify_pins:
        require(list(PROJECTION_PINS) == list(chosen), "temporal_projection_pin_inventory_mismatch")
        require(all(item["public_projection_sha256"] == PROJECTION_PINS[item["question_id"]] for item in annotations),
                "temporal_projection_pin_mismatch")
    manifest = {"cohort": COHORT, "question_type": QUESTION_TYPE, "development_cohort": hundred.COHORT,
                "development_selection_version": development["version"],
                "selection_rule": "every answerable temporal-reasoning question of the frozen development selection, in "
                                  "its rank order; temporal abstention questions left out",
                "temporal_abstention_left_out": list(left_out), "declared_questions": len(chosen),
                "case_ids": list(chosen), "runner_document_version": VERSION,
                "opaque_identity_domain": hundred.IDENTITY_DOMAIN, "configuration": CONFIGURATION,
                "source": development["source"], "cases": annotations}
    return selected, manifest
