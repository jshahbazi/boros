#!/usr/bin/env python3
"""Provider-neutral experimental navigation over preserved original exchanges.

No provider calls, credentials, corpus reads or file writes occur here. Source
identities and source-time locators stay in the host. Model-facing projections
use ordinal identities; deterministic lexical maps guide navigation, and final
evidence always consists of complete, verified original exchange projections.
"""
from __future__ import annotations

import base64
import copy
import datetime
import hashlib
import hmac
import math
import os
import re
import unicodedata
from collections import Counter

import orientation_zoom as o

VERSION = "boros-history-navigation-v2"
MAX_QUERY_BYTES = 16_384
MAX_QUERY_TERMS = 256
MAX_PAGE_SIZE = 128
MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_CURSOR_BYTES = 2_048
GROUP_SIZE = 8
TOKEN = re.compile(r"[^\W_]+", re.UNICODE)
DATE = re.compile(r"^(\d{4})[-/](\d{2})[-/](\d{2})(?:$|[ T(])")
NavigationError = o.ExperimentError


def _require(value, code):
    o.require(value, code)


def _int(value, minimum, maximum, code):
    _require(type(value) is int and minimum <= value <= maximum, code)


def _text(value, maximum, code):
    _require(isinstance(value, str), code)
    try:
        raw = value.encode("utf-8")
    except UnicodeError:
        raise NavigationError(code) from None
    _require(len(raw) <= maximum, code)
    return raw


def _normalized(term):
    # Mirrors unicode61's usual accent-insensitive Latin matching sufficiently
    # for lexical weights. SQLite remains authoritative about actual matches.
    return "".join(c for c in unicodedata.normalize("NFD", term.lower())
        if not unicodedata.combining(c))


def _tokens(text):
    return [match.group(0) for match in TOKEN.finditer(text)]


def _date(value):
    match = DATE.match(value) if isinstance(value, str) else None
    if match:
        try:
            return datetime.date(*(int(part) for part in match.groups())).isoformat()
        except ValueError:
            pass
    return None


def _source_time(value):
    original = value.get("original_value") if isinstance(value, dict) else value
    # Location pointers and arbitrary imported metadata are host-only. A missing
    # original date stays unknown; ingestion time is never substituted.
    if isinstance(original, str) and original:
        _text(original, 4_096, "source_date_bound_invalid")
        return {"original_value": original}
    return None


def _fts_query(terms):
    return " OR ".join('"' + term.replace('"', '""') + '"' for term in terms)


class NavigationHistory:
    def __init__(self, records):
        # Reuse the accepted original field/order/status and complete-exchange
        # contracts, then remap before constructing any model-visible inventory.
        original = o.History(records)
        try:
            self._originals = copy.deepcopy(original.records)
            self.source_sha256 = original.source_sha256
            opaque = []
            self._host_event_ids = {}
            self._host_session_ids = {}
            for index, record in enumerate(self._originals):
                event_id = f"e{index:06d}"
                session_id = f"s{record['session_index']:06d}"
                self._host_event_ids[event_id] = record["event_id"]
                self._host_session_ids[session_id] = record["original_session_id"]
                opaque.append({**record, "event_id": event_id,
                    "original_session_id": session_id,
                    "source_time": _source_time(record["source_time"])})
        finally:
            original.close()
        self._history = o.History(opaque)
        self._records = self._history.records
        self._by_id = self._history.by_id
        self.ordinal = dict(self._history.ordinal)
        self._blocks, self._regions, self._event_block = {}, {}, {}
        for index, block in enumerate(self._history.blocks.values()):
            block_id = f"b{index:06d}"
            session_index = self._by_id[block["source_ids"][0]]["session_index"]
            region_id = f"s{session_index:06d}"
            source_ids = list(block["source_ids"])
            self._blocks[block_id] = {"block_id": block_id, "region_id": region_id,
                "source_ids": source_ids}
            region = self._regions.setdefault(region_id, {"region_id": region_id,
                "block_ids": [], "source_ids": []})
            region["block_ids"].append(block_id)
            region["source_ids"].extend(source_ids)
            for event_id in source_ids:
                self._event_block[event_id] = block_id
        self.projection_sha256 = o.digest(o.canonical(self._records))
        self._cursor_key = os.urandom(32)
        self._block_ids = list(self._blocks)
        self._block_ordinal = {block_id: index for index, block_id in enumerate(self._blocks)}
        self._block_terms, self._block_bytes, self._block_dates = {}, {}, {}
        self._df = Counter()
        exchange_texts = []
        for block_id, block in self._blocks.items():
            rows = [self._by_id[event_id] for event_id in block["source_ids"]]
            text = "\n".join(row["content"] for row in rows)
            terms = Counter(_normalized(term) for term in _tokens(text)
                if term.lower() not in o.STOPWORDS and len(term.encode()) <= 128)
            self._block_terms[block_id] = terms
            self._df.update(terms.keys())
            self._block_bytes[block_id] = sum(len(row["content"].encode()) for row in rows)
            self._block_dates[block_id] = [self._record_date(row) for row in rows]
            exchange_texts.append({"content": text})
        try:
            self._exchange_fts = o._SystemFTS(exchange_texts)
        except BaseException:
            self._history.close()
            raise
        self._nodes = {}
        for region_id, region in self._regions.items():
            self._nodes[region_id] = {"region_id": region_id, "level": 0,
                "children": list(region["block_ids"]), "block_ids": list(region["block_ids"])}
        layer, level, group_index = list(self._regions), 1, 0
        while len(layer) > GROUP_SIZE:
            parents = []
            for offset in range(0, len(layer), GROUP_SIZE):
                children = layer[offset:offset + GROUP_SIZE]
                region_id = f"g{group_index:06d}"; group_index += 1
                self._nodes[region_id] = {"region_id": region_id, "level": level,
                    "children": children, "block_ids": [block_id for child in children
                        for block_id in self._nodes[child]["block_ids"]]}
                parents.append(region_id)
            layer, level = parents, level + 1
        self.root_region_id = "h000000"
        self._nodes[self.root_region_id] = {"region_id": self.root_region_id,
            "level": level, "children": layer, "block_ids": list(self._blocks)}
        self._node_views = {region_id: self._describe(node["block_ids"], region_id, node["level"])
            for region_id, node in self._nodes.items()}
        self._node_views.update({block_id: self._describe([block_id], block_id, -1)
            for block_id in self._blocks})

    @property
    def model_records(self):
        return copy.deepcopy(self._records)

    @property
    def by_id(self):
        return copy.deepcopy(self._by_id)

    @property
    def blocks(self):
        return copy.deepcopy(self._blocks)

    @property
    def regions(self):
        return copy.deepcopy(self._regions)

    def close(self):
        self._history.close()
        self._exchange_fts.close()

    def host_original_ids(self, opaque_ids):
        """Host-only identity translation; never add this result to model input."""
        _require(isinstance(opaque_ids, (list, tuple)) and all(isinstance(value, str)
            and value in self._host_event_ids for value in opaque_ids), "source_identity_unknown")
        return [self._host_event_ids[value] for value in opaque_ids]

    def _record_date(self, row):
        value = row["source_time"]
        return _date(value["original_value"]) if value is not None else None

    def _rows(self, block_ids):
        ids = sorted((event_id for block_id in block_ids
            for event_id in self._blocks[block_id]["source_ids"]), key=self.ordinal.__getitem__)
        return [copy.deepcopy(self._by_id[event_id]) for event_id in ids]

    def _ids(self, values, code="block_identity_invalid"):
        _require(isinstance(values, (list, tuple, set, frozenset)) and len(values) <= len(self._blocks)
            and all(isinstance(value, str) and value in self._blocks for value in values), code)
        return list(dict.fromkeys(values))

    def _describe(self, block_ids, region_id, level):
        frequency, surfaces, entities = Counter(), {}, Counter()
        cue_sources, cue_blocks = {}, {}
        source_ids, dates, unknown = [], [], 0
        for block_id in block_ids:
            frequency.update(self._block_terms[block_id])
            for event_id in self._blocks[block_id]["source_ids"]:
                row = self._by_id[event_id]
                source_ids.append(event_id)
                for token in _tokens(row["content"]):
                    if token.lower() not in o.STOPWORDS and len(token.encode()) <= 128:
                        normalized = _normalized(token)
                        surfaces.setdefault(normalized, token)
                        if event_id not in cue_sources.setdefault(normalized, []) and len(cue_sources[normalized]) < 3:
                            cue_sources[normalized].append(event_id)
                        if block_id not in cue_blocks.setdefault(normalized, []) and len(cue_blocks[normalized]) < 3:
                            cue_blocks[normalized].append(block_id)
                        if any(char.isupper() for char in token) and len(token) > 1:
                            entities[token] += 1
                value = row["source_time"]
                if value is not None:
                    dates.append(value["original_value"])
                if self._record_date(row) is None:
                    unknown += 1
        scored = sorted(frequency, key=lambda term: (
            -(1 + math.log(frequency[term])) * self._idf(term), term))
        literal_dates = list(dict.fromkeys(dates))
        known_dates = sorted(filter(None, (_date(value) for value in literal_dates)))
        return {"region_id": region_id, "level": level,
            "topic_cues": [surfaces[term] for term in scored[:12]],
            "cue_links": [{"cue": surfaces[term], "source_ids": cue_sources[term],
                "block_ids": cue_blocks[term]} for term in scored[:12]],
            "entity_cues": sorted(entities, key=lambda term: (-entities[term], term))[:8],
            "cues_are_literal_terms_not_facts": True,
            "source_records": len(source_ids), "complete_exchange_blocks": len(block_ids),
            "source_links": source_ids[:4], "source_links_are_sample": len(source_ids) > 4,
            "block_links": block_ids[:8], "block_links_are_sample": len(block_ids) > 8,
            "available_dates": literal_dates[:8], "available_date_count": len(literal_dates),
            "available_dates_are_sample": len(literal_dates) > 8,
            "first_civil_date": known_dates[0] if known_dates else None,
            "last_civil_date": known_dates[-1] if known_dates else None,
            "unknown_date_records": unknown}

    def _idf(self, term):
        frequency = self._df.get(term, 0)
        return math.log(1 + (len(self._blocks) - frequency + 0.5) / (frequency + 0.5))

    def manifest(self):
        return {"version": VERSION, "source_sha256": self.source_sha256,
            "projection_sha256": self.projection_sha256,
            "source_records": len(self._records), "source_sessions": len(self._regions),
            "complete_exchange_blocks": len(self._blocks),
            "source_content_bytes": sum(self._block_bytes.values()),
            "sqlite_version": self._history.fts.version,
            "original_identity_map_is_host_only": True,
            "navigation_is_question_blind": True,
            "navigation_summaries_are_answer_evidence": False}

    def _cursor(self, operation, binding, offset):
        payload = o.canonical({"version": VERSION, "operation": operation,
            "source": self.source_sha256, "binding": o.digest(o.canonical(binding)), "offset": offset})
        signature = hmac.new(self._cursor_key, payload, hashlib.sha256).hexdigest().encode()
        return base64.urlsafe_b64encode(payload + b"." + signature).decode("ascii")

    def _offset(self, cursor, operation, binding, total):
        if cursor is None:
            return 0
        _text(cursor, MAX_CURSOR_BYTES, "cursor_invalid")
        try:
            raw = base64.b64decode(cursor.encode("ascii"), altchars=b"-_", validate=True)
            payload, signature = raw.rsplit(b".", 1)
            expected = hmac.new(self._cursor_key, payload, hashlib.sha256).hexdigest().encode()
            _require(hmac.compare_digest(signature, expected), "cursor_invalid")
            value = o.strict_json(payload)
        except (ValueError, UnicodeError, NavigationError):
            raise NavigationError("cursor_invalid") from None
        _require(isinstance(value, dict) and set(value) == {"version", "operation", "source", "binding", "offset"}
            and value["version"] == VERSION and value["operation"] == operation
            and value["source"] == self.source_sha256
            and value["binding"] == o.digest(o.canonical(binding))
            and type(value["offset"]) is int and 0 <= value["offset"] <= total, "cursor_invalid")
        return value["offset"]

    def overview(self, region_id=None, *, cursor=None, page_size=16):
        _int(page_size, 1, MAX_PAGE_SIZE, "page_bound_invalid")
        region_id = self.root_region_id if region_id is None else region_id
        _require(isinstance(region_id, str) and region_id in self._nodes, "overview_region_unknown")
        children = self._nodes[region_id]["children"]
        binding = {"region_id": region_id}
        offset = self._offset(cursor, "overview", binding, len(children))
        ids = children[offset:offset + page_size]
        end = offset + len(ids)
        coverage = "complete" if end == len(children) else "paged"
        header = copy.deepcopy(self._node_views[self.root_region_id])
        header.update({"whole_history_regions": len(self._regions),
            "whole_history_indexed_records": len(self._records),
            "aggregate_covers_all_original_records": True,
            "detail_coverage": "navigation_page_complete" if coverage == "complete" else "navigation_page_partial",
            "original_record_details_included": False,
            "navigation_instruction": "Follow region links and next_cursor to inspect details; cues are not answer evidence."})
        entries = [copy.deepcopy(self._node_views[value]) for value in ids]
        return {"header": header, "entries": entries, "coverage": coverage,
            "next_cursor": self._cursor("overview", binding, end) if end < len(children) else None,
            "receipt": {**self.manifest(), "action": "overview", "region_id": region_id,
                "entry_offset": offset, "returned_entries": len(entries), "total_entries": len(children),
                "view_sha256": o.digest(o.canonical({"header": header, "entries": entries}))}}

    def validate_evidence(self, evidence):
        self.evidence_block_ids(evidence)

    def evidence_block_ids(self, evidence):
        _require(isinstance(evidence, list), "evidence_invalid")
        ids = []
        for row in evidence:
            _require(isinstance(row, dict) and set(row) == o.RECORD_KEYS
                and isinstance(row.get("event_id"), str) and row["event_id"] in self._by_id,
                "evidence_source_invalid")
            _require(o.canonical(row) == o.canonical(self._by_id[row["event_id"]]), "evidence_original_mismatch")
            _require(row["event_id"] not in ids, "evidence_duplicate")
            ids.append(row["event_id"])
        blocks = list(dict.fromkeys(self._event_block[event_id] for event_id in ids))
        _require(set(ids) == {event_id for block_id in blocks for event_id in self._blocks[block_id]["source_ids"]},
            "evidence_exchange_incomplete")
        _require(ids == sorted(ids, key=self.ordinal.__getitem__), "evidence_order_invalid")
        return blocks

    def _pack_receipt(self, action, packed, **extra):
        return {**self.manifest(), "action": action, "evidence_sha256": packed["evidence_sha256"],
            "accepted_block_ids": list(packed["accepted_block_ids"]),
            "dropped_block_ids": list(packed["dropped_block_ids"]),
            "source_records_returned_to_host": len(packed["evidence"]), "content_bytes": packed["content_bytes"],
            "model_delivery_established": False,
            "sources": [{"event_id": row["event_id"], "offset": 0,
                "byte_length": len(row["content"].encode()),
                "content_sha256": o.digest(row["content"].encode()),
                "original_record_sha256": o.digest(o.canonical(self._originals[self.ordinal[row["event_id"]]]))}
                for row in packed["evidence"]], **extra}

    def pack(self, block_ids, *, maximum_bytes=48_000, token_fits=None,
            pinned_block_ids=(), excluded_block_ids=()):
        _int(maximum_bytes, 0, MAX_FRAME_BYTES, "evidence_bound_invalid")
        _require(token_fits is None or callable(token_fits), "token_admission_invalid")
        priorities = self._ids(block_ids)
        pins = self._ids(pinned_block_ids, "pinned_block_invalid")
        excluded = set(self._ids(excluded_block_ids, "excluded_block_invalid"))
        _require(not excluded.intersection(pins), "pinned_block_excluded")
        accepted, dropped, used = [], [], 0

        def fits(candidate_ids):
            if sum(self._block_bytes[block_id] for block_id in candidate_ids) > maximum_bytes:
                return False
            if token_fits is not None:
                decision = self._token_decision(token_fits, candidate_ids)
                _require(type(decision) is bool, "token_admission_invalid")
                return decision
            return True

        # Admission sees all pins as one atomic reservation. It cannot silently
        # displace a pinned old correction when later tool evidence arrives.
        if pins:
            _require(fits(pins), "pinned_evidence_does_not_fit")
        accepted.extend(pins); used = sum(self._block_bytes[block_id] for block_id in pins)
        for block_id in priorities:
            if block_id in excluded or block_id in accepted:
                continue
            if fits(accepted + [block_id]):
                accepted.append(block_id); used += self._block_bytes[block_id]
            else:
                dropped.append(block_id)
        rows = self._rows(accepted)
        result = {"evidence": rows, "accepted_block_ids": accepted, "dropped_block_ids": dropped,
            "content_bytes": used, "evidence_sha256": o.digest(o.canonical(rows))}
        result["receipt"] = self._pack_receipt("pack", result,
            pinned_block_ids=pins, excluded_block_count=len(excluded),
            candidate_blocks_reached=len([value for value in priorities if value not in excluded]),
            fitted_blocks=len(accepted), dropped_blocks=len(dropped))
        return result

    def _token_decision(self, token_fits, block_ids):
        try:
            return token_fits(self._rows(block_ids))
        except NavigationError:
            raise
        except Exception:
            raise NavigationError("token_admission_failed") from None

    def recent(self, *, maximum_bytes=32_000, token_fits=None, pinned_block_ids=(), excluded_block_ids=()):
        # Count a newest-first complete-exchange byte pack as one component,
        # skipping oversized units so smaller older exchanges remain reachable.
        # Then reduce
        # it geometrically if necessary. Per-exchange remote counting of every
        # recent candidate would spend the episode before investigation starts.
        packed = self.pack(list(reversed(self._blocks)), maximum_bytes=maximum_bytes,
            pinned_block_ids=pinned_block_ids, excluded_block_ids=excluded_block_ids)
        if token_fits is None:
            return packed
        _require(callable(token_fits), "token_admission_invalid")
        pins = self._ids(pinned_block_ids, "pinned_block_invalid")
        accepted = list(packed["accepted_block_ids"])
        removed = []
        while True:
            decision = self._token_decision(token_fits, accepted)
            _require(type(decision) is bool, "token_admission_invalid")
            if decision:
                break
            optional = [block_id for block_id in accepted if block_id not in pins]
            _require(optional, "pinned_evidence_does_not_fit" if pins else "recent_empty_does_not_fit")
            retain = optional[:len(optional) // 2]
            removed.extend(block_id for block_id in optional if block_id not in retain)
            accepted = pins + retain
        result = self.pack(accepted, maximum_bytes=maximum_bytes,
            pinned_block_ids=pins, excluded_block_ids=excluded_block_ids)
        result["dropped_block_ids"] = list(dict.fromkeys(packed["dropped_block_ids"] + removed))
        result["receipt"] = self._pack_receipt("recent", result,
            pinned_block_ids=pins, candidate_blocks_reached=len(self._blocks),
            fitted_blocks=len(accepted), dropped_blocks=len(result["dropped_block_ids"]),
            token_reduction_is_geometric=True)
        return result

    def _time_filter(self, value):
        if value is None:
            return None
        _require(isinstance(value, dict) and set(value) == {"start", "end", "include_unknown"}
            and type(value["include_unknown"]) is bool, "time_filter_invalid")
        for key in ("start", "end"):
            _require(value[key] is None or (isinstance(value[key], str) and len(value[key]) == 10
                and _date(value[key]) == value[key]), "time_filter_invalid")
        _require(value["start"] is None or value["end"] is None or value["start"] <= value["end"],
            "time_filter_invalid")
        return copy.deepcopy(value)

    def _eligible(self, block_id, time_filter):
        if time_filter is None:
            return True
        for value in self._block_dates[block_id]:
            if value is None:
                if time_filter["include_unknown"]:
                    return True
            elif (time_filter["start"] is None or value >= time_filter["start"]) and (
                    time_filter["end"] is None or value <= time_filter["end"]):
                return True
        return False

    def query_terms(self, query):
        raw = _text(query, MAX_QUERY_BYTES, "query_invalid")
        _require(raw and query.strip(), "query_invalid")
        terms = list(dict.fromkeys(token.lower() for token in _tokens(query)
            if token.lower() not in o.STOPWORDS and len(token.encode()) <= 128))
        _require(terms, "search_terms_empty")
        # Reject overlarge work rather than silently ignoring later anchors.
        _require(len(terms) <= MAX_QUERY_TERMS, "query_term_bound_exceeded")
        return sorted(terms, key=lambda term: (-self._idf(_normalized(term)), term))

    def _all_matches(self, index, terms):
        return [ordinal - 1 for ordinal in index._statement(
            "SELECT rowid FROM originals WHERE originals MATCH ? ORDER BY bm25(originals),rowid DESC",
            (_fts_query(terms),), rows=True)]

    def _ranked(self, query):
        terms = self.query_terms(query)
        record_hits = self._all_matches(self._history.fts, terms)
        exchange_hits = self._all_matches(self._exchange_fts, terms)
        reached = set(self._block_ids[index] for index in exchange_hits)
        reached.update(self._event_block[self._records[index]["event_id"]] for index in record_hits)
        fts_rank = {self._block_ids[index]: rank for rank, index in enumerate(exchange_hits)}
        normalized = list(dict.fromkeys(_normalized(term) for term in terms))

        def score(block_id):
            frequency = self._block_terms[block_id]
            relevance = sum(self._idf(term) * (1 + min(2, math.log(frequency[term])))
                for term in normalized if frequency[term])
            relevance += 0.05 / (1 + fts_rank.get(block_id, len(self._blocks)))
            # Explicit cost-aware order: a long exchange must contribute enough
            # query evidence to justify consuming most of the frame.
            return relevance / math.sqrt(1 + self._block_bytes[block_id] / 512)
        ranked = sorted(reached, key=lambda block_id: (-score(block_id), -self._block_ordinal[block_id]))
        return ranked, {"query_sha256": o.digest(query.encode()), "query_term_count": len(terms),
            "record_fts_hits": len(record_hits), "exchange_fts_hits": len(exchange_hits),
            "candidate_blocks_matched": len(reached), "full_original_index_searched": True}

    def _page(self, operation, candidates, binding, *, cursor, page_size, maximum_bytes,
            token_fits, pinned_block_ids, excluded_block_ids, extra):
        _int(page_size, 1, MAX_PAGE_SIZE, "page_bound_invalid")
        pins = self._ids(pinned_block_ids, "pinned_block_invalid")
        excluded = self._ids(excluded_block_ids, "excluded_block_invalid")
        binding = {**binding, "excluded_block_ids": sorted(excluded)}
        candidates = [block_id for block_id in candidates if block_id not in set(excluded)]
        offset = self._offset(cursor, operation, binding, len(candidates))
        page = candidates[offset:offset + page_size]
        end = offset + len(page)
        packed = self.pack(page, maximum_bytes=maximum_bytes, token_fits=token_fits,
            pinned_block_ids=pins, excluded_block_ids=excluded)
        has_more = end < len(candidates)
        coverage = "paged_allowance_limited" if has_more and packed["dropped_block_ids"] else (
            "paged" if has_more else "allowance_limited" if packed["dropped_block_ids"] else "complete")
        packed.update({"candidate_block_ids": page, "coverage": coverage,
            "next_cursor": self._cursor(operation, binding, end) if has_more else None})
        packed["receipt"] = self._pack_receipt(operation, packed,
            candidate_blocks_reached=len(page), candidate_blocks_available=len(candidates),
            fitted_blocks=len([block_id for block_id in page if block_id in packed["accepted_block_ids"]]),
            dropped_blocks=len(packed["dropped_block_ids"]), candidate_offset=offset,
            pinned_block_ids=pins, excluded_block_count=len(excluded),
            candidate_coverage_complete=not has_more,
            host_projection_coverage_complete=not has_more and not packed["dropped_block_ids"],
            **extra)
        return packed

    def search(self, query, *, cursor=None, page_size=32, time_filter=None,
            maximum_bytes=48_000, token_fits=None, pinned_block_ids=(), excluded_block_ids=()):
        _int(page_size, 1, MAX_PAGE_SIZE, "page_bound_invalid")
        time_filter = self._time_filter(time_filter)
        ranked, extra = self._ranked(query)
        unknown = sum(any(value is None for value in self._block_dates[block_id]) for block_id in ranked)
        eligible = [block_id for block_id in ranked if self._eligible(block_id, time_filter)]
        return self._page("search", eligible, {"query_sha256": extra["query_sha256"], "time_filter": time_filter},
            cursor=cursor, page_size=page_size, maximum_bytes=maximum_bytes, token_fits=token_fits,
            pinned_block_ids=pinned_block_ids, excluded_block_ids=excluded_block_ids,
            extra={**extra, "candidate_blocks_with_unknown_dates": unknown,
                "time_filter_applied": time_filter is not None, "time_filter_sha256": o.digest(o.canonical(time_filter)),
                "time_filter_excluded_blocks": len(ranked) - len(eligible),
                "temporal_precision": "literal_original_civil_day"})

    def zoom(self, region_id, *, cursor=None, page_size=32, maximum_bytes=48_000,
            token_fits=None, pinned_block_ids=(), excluded_block_ids=()):
        _int(page_size, 1, MAX_PAGE_SIZE, "page_bound_invalid")
        _require(isinstance(region_id, str) and (region_id in self._nodes or region_id in self._blocks),
            "zoom_region_unknown")
        candidates = self._nodes[region_id]["block_ids"] if region_id in self._nodes else [region_id]
        return self._page("zoom", candidates, {"region_id": region_id}, cursor=cursor, page_size=page_size,
            maximum_bytes=maximum_bytes, token_fits=token_fits, pinned_block_ids=pinned_block_ids,
            excluded_block_ids=excluded_block_ids,
            extra={"region_id": region_id, "full_region_inventory_available": True})
