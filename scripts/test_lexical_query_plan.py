#!/usr/bin/env python3
"""Exercise the native lexical SQL through the macOS system SQLite library.

These public synthetic contracts preserve scoped ordered results while checking
that the real SQL forces FTS to execute before event lookups. No model or native
application build is required, and no private store is opened.
"""
import ctypes
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SQLITE_LIBRARY = "/usr/lib/libsqlite3.dylib"


class SystemSQLite:
    def __init__(self):
        self.lib = ctypes.CDLL(SQLITE_LIBRARY)
        signatures = {
            "sqlite3_open": ([ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            "sqlite3_close": ([ctypes.c_void_p], ctypes.c_int),
            "sqlite3_prepare_v2": ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int,
                                    ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p], ctypes.c_int),
            "sqlite3_bind_text": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p,
                                   ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
            "sqlite3_bind_blob": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p,
                                   ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
            "sqlite3_bind_int64": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_longlong], ctypes.c_int),
            "sqlite3_bind_null": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "sqlite3_step": ([ctypes.c_void_p], ctypes.c_int),
            "sqlite3_finalize": ([ctypes.c_void_p], ctypes.c_int),
            "sqlite3_column_count": ([ctypes.c_void_p], ctypes.c_int),
            "sqlite3_column_type": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "sqlite3_column_int64": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_longlong),
            "sqlite3_column_double": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_double),
            "sqlite3_column_blob": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_void_p),
            "sqlite3_column_bytes": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "sqlite3_libversion": ([], ctypes.c_char_p),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = arguments, result
        self.db = ctypes.c_void_p()
        if self.lib.sqlite3_open(b":memory:", ctypes.byref(self.db)) != 0:
            raise RuntimeError("system SQLite open failed")

    def close(self):
        if self.db:
            if self.lib.sqlite3_close(self.db) != 0:
                raise RuntimeError("system SQLite close failed")
            self.db = None

    def query(self, sql, bindings=()):
        statement = ctypes.c_void_p()
        if self.lib.sqlite3_prepare_v2(self.db, sql.encode(), -1,
                                      ctypes.byref(statement), None) != 0:
            raise RuntimeError("system SQLite prepare failed")
        try:
            for index, value in enumerate(bindings, 1):
                if value is None:
                    result = self.lib.sqlite3_bind_null(statement, index)
                elif isinstance(value, int):
                    result = self.lib.sqlite3_bind_int64(statement, index, value)
                else:
                    encoded = value if isinstance(value, bytes) else value.encode()
                    method = self.lib.sqlite3_bind_blob if isinstance(value, bytes) else self.lib.sqlite3_bind_text
                    result = method(statement, index, encoded, len(encoded), ctypes.c_void_p(-1))
                if result != 0:
                    raise RuntimeError("system SQLite bind failed")
            rows = []
            while True:
                status = self.lib.sqlite3_step(statement)
                if status == 101:
                    return rows
                if status != 100:
                    raise RuntimeError("system SQLite step failed")
                row = []
                for index in range(self.lib.sqlite3_column_count(statement)):
                    kind = self.lib.sqlite3_column_type(statement, index)
                    if kind == 5:
                        value = None
                    elif kind == 1:
                        value = self.lib.sqlite3_column_int64(statement, index)
                    elif kind == 2:
                        value = self.lib.sqlite3_column_double(statement, index)
                    else:
                        size = self.lib.sqlite3_column_bytes(statement, index)
                        pointer = self.lib.sqlite3_column_blob(statement, index)
                        raw = ctypes.string_at(pointer, size) if size else b""
                        value = raw if kind == 4 else raw.decode()
                    row.append(value)
                rows.append(tuple(row))
        finally:
            self.lib.sqlite3_finalize(statement)


def native_sql_parts():
    text = (ROOT / "Sources/Boros/MemoryStore.swift").read_text()
    patterns = {
        "metadata": r'"(SELECT e\.sequence,e\.id,[^"\n]+)" \+ upper \+ exclusion \+ "([^"\n]+)"',
        "payload": r'let sql = "(SELECT e\.id,e\.conversation_id,[^"\n]+)" \+ upperBound \+ exclusions \+ "([^"\n]+)"',
    }
    result = {}
    for name, pattern in patterns.items():
        matches = re.findall(pattern, text)
        if len(matches) != 1:
            raise AssertionError("native lexical SQL extraction must be unique")
        result[name] = matches[0]
    return result


def lexical_sql(parts, terms, *, project="scope-a", all_terms=False,
                frontier=None, exclusions=(), limit=100, previous_join=False):
    prefix, suffix = parts
    if previous_join:
        prefix = prefix.replace("event_fts CROSS JOIN events", "event_fts JOIN events")
    expression = (" AND " if all_terms else " OR ").join(
        '"' + term.replace('"', '""') + '"' for term in terms)
    sql, bindings = prefix, [expression, project]
    if frontier is not None:
        sql += " AND e.sequence<=?"
        bindings.append(frontier)
    if exclusions:
        sql += " AND e.id NOT IN (SELECT value FROM json_each(?))"
        bindings.append(json.dumps(sorted(exclusions)))
    return sql + suffix, bindings + [limit]


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS native SQLite library")
class LexicalQueryPlanContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parts = native_sql_parts()
        cls.sqlite = SystemSQLite()
        cls.sqlite.query("CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT,"
                         "id TEXT NOT NULL UNIQUE,conversation_id TEXT NOT NULL,project_id TEXT NOT NULL,"
                         "role TEXT NOT NULL,status TEXT NOT NULL,turn_id TEXT NOT NULL,created_at TEXT NOT NULL,"
                         "digest TEXT NOT NULL,byte_count INTEGER NOT NULL,payload BLOB NOT NULL,source_time_json TEXT)")
        cls.sqlite.query("CREATE INDEX event_conversation ON events(conversation_id,sequence)")
        cls.sqlite.query("CREATE INDEX event_project ON events(project_id,sequence)")
        cls.sqlite.query("CREATE VIRTUAL TABLE event_fts USING fts5(text,content='')")
        cls.records = [
            (1, "tie-old", "scope-a", "alpha beta"),
            (2, "foreign", "scope-b", "alpha beta"),
            (3, "tie-new", "scope-a", "alpha beta"),
            (4, "alpha-only", "scope-a", "alpha gamma"),
            (5, "beta-only", "scope-a", "beta gamma"),
            (6, "unicode", "scope-a", "café naïve résumé"),
            (7, "quoted", "scope-a", 'literal "quoted" token'),
            (8, "combining", "scope-a", "cafe\u0301 resume\u0301"),
            (9, "scope-case", "Scope-a", "alpha beta"),
            (10, "after-frontier", "scope-a", "alpha beta"),
        ]
        cls.records += [(sequence, "filler-" + str(sequence), "scope-a", "public filler material")
                        for sequence in range(11, 411)]
        for sequence, event_id, project, payload in cls.records:
            raw = payload.encode()
            cls.sqlite.query("INSERT INTO events VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                             (sequence, event_id, "conversation-" + project, project,
                              "human" if sequence % 2 else "assistant", "complete", "turn-" + str(sequence),
                              "public-fixture-time", hashlib.sha256(raw).hexdigest(), len(raw), raw,
                              json.dumps({"fixture_sequence": sequence})))
            cls.sqlite.query("INSERT INTO event_fts(rowid,text) VALUES (?,?)", (sequence, payload))

    @classmethod
    def tearDownClass(cls):
        cls.sqlite.close()

    def paired(self, terms, **options):
        results = {}
        for name, parts in self.parts.items():
            current = self.sqlite.query(*lexical_sql(parts, terms, **options))
            previous = self.sqlite.query(*lexical_sql(parts, terms, previous_join=True, **options))
            self.assertEqual(current, previous, name + " must preserve every ordered projected value")
            event_index = 1 if name == "metadata" else 0
            results[name] = [row[event_index] for row in current]
            for row in current:
                # Both projections contain project/status/digest/byte_count and source-time.
                self.assertEqual(row[3 if name == "metadata" else 2], options.get("project", "scope-a"))
        self.assertEqual(results["metadata"], results["payload"])
        return results["metadata"]

    def test_actual_native_queries_force_fts_before_primary_key_event_lookup(self):
        for name, parts in self.parts.items():
            self.assertIn("event_fts CROSS JOIN events e ON e.sequence=event_fts.rowid", parts[0])
            sql, bindings = lexical_sql(parts, ["alpha"], frontier=8, exclusions=["tie-old"], limit=2)
            details = [row[3] for row in self.sqlite.query("EXPLAIN QUERY PLAN " + sql, bindings)]
            fts = [index for index, detail in enumerate(details)
                   if "event_fts VIRTUAL TABLE INDEX" in detail and "M" in detail]
            event = [index for index, detail in enumerate(details)
                     if "SEARCH e USING INTEGER PRIMARY KEY" in detail]
            self.assertEqual(len(fts), 1, name)
            self.assertEqual(len(event), 1, name)
            self.assertLess(fts[0], event[0], name)
            self.assertFalse(any("event_project" in detail for detail in details), name)

    def test_all_and_any_term_modes_preserve_results(self):
        self.assertEqual(set(self.paired(["alpha", "beta"], all_terms=True)),
                         {"tie-old", "tie-new", "after-frontier"})
        self.assertEqual(set(self.paired(["alpha", "beta"])),
                         {"tie-old", "tie-new", "after-frontier", "alpha-only", "beta-only"})

    def test_scope_filters_apply_before_result_limit_and_use_exact_identity(self):
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True, project="scope-b", limit=1), ["foreign"])
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True, project="Scope-a", limit=1), ["scope-case"])
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True, project="missing", limit=1), [])

    def test_frontier_and_exclusions_apply_before_limit(self):
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True, frontier=8,
                                     exclusions=["tie-new", "foreign"], limit=1), ["tie-old"])
        self.assertEqual(self.paired(["alpha"], frontier=0, limit=1), [])
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True,
                                     exclusions=["after-frontier", "tie-new", "tie-old"], limit=1), [])

    def test_identical_bm25_ties_remain_newest_first(self):
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True),
                         ["after-frontier", "tie-new", "tie-old"])
        self.assertEqual(self.paired(["alpha", "beta"], all_terms=True, frontier=8),
                         ["tie-new", "tie-old"])

    def test_unicode_quotes_and_missing_terms_preserve_results(self):
        self.assertEqual(set(self.paired(["café", "résumé"], all_terms=True)), {"unicode", "combining"})
        self.assertEqual(self.paired(['"quoted"']), ["quoted"])
        self.assertEqual(self.paired(["missingneedle"]), [])
        self.assertEqual(self.paired(['alpha" OR "missingneedle'], all_terms=True), [])

    def test_payload_projection_preserves_original_bytes_and_metadata(self):
        sql, bindings = lexical_sql(self.parts["payload"], ["naïve"])
        rows = self.sqlite.query(sql, bindings)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row[0], "unicode")
        self.assertEqual(row[9], "café naïve résumé".encode())
        self.assertEqual(row[8], len(row[9]))
        self.assertEqual(row[7], hashlib.sha256(row[9]).hexdigest())
        self.assertEqual(json.loads(row[10]), {"fixture_sequence": 6})


if __name__ == "__main__":
    unittest.main()
