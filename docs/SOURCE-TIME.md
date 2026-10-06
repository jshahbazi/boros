# Original source-time evidence

Boros records when it accepted an event in `created_at`. Imported messages may separately carry an original source date. These clocks have different meanings. Missing original dates remain unknown.

## Import contract

The OpenAI role-message converter accepts an optional string `timestamp` in JSON or JSONL. It preserves the original artifact bytes, constructs the exact selected message pointer and emits native import v2. Undated conversions retain v1. Native v2 validates the entire input before prefix selection, including dates in later messages.

Each source-time object contains exactly these fields:

| Field | Meaning |
|---|---|
| `value` | Normalized proleptic Gregorian civil date or date/time; timezone is separate |
| `precision` | `day`, `minute`, `second`, or `fractional_second` |
| `timezone` | Explicit `Z` or numeric offset, otherwise `unspecified` |
| `source_sha256` | SHA-256 of the complete original artifact |
| `locator` | RFC 6901 JSON pointer to the original date literal; JSONL is interpreted as an ordered record array |
| `original_value` | Exact original string at that location |

Accepted forms are `YYYY-MM-DD`, an ISO date/time with `T`, optional seconds and one to nine fractional digits, and an optional `Z` or numeric offset. The adapter also accepts `YYYY/MM/DD (Tue)` with an optional ` HH:mm`; the actual weekday must match. Years are 1–9999, valid Gregorian days are required, and explicit offsets are bounded to 14 hours. Leap seconds, unknown-offset `-00:00`, epoch values, locale guessing and named timezones are refused. An unspecified timezone is never assigned the host timezone.

Native v2 requires the original artifact when dates are supplied. It verifies the artifact hash, metadata grammar, normalization, strict pointer resolution and exact date-literal bytes. Duplicate and Unicode-equivalent original JSON keys are refused for dated input. The converter binds timestamps to actual message locations; a direct native input supplies its own association. This contract verifies recorded evidence, not whether an external timestamp was historically truthful. BEAM batch anchors, DevGPT sharing dates and account-export timestamps have no adapter yet.

## Storage and delivery

Schema 10 adds nullable canonical `events.source_time_json`, bounded to 4096 bytes. Insertion, payload publication and lexical indexing share one transaction. Exact retries include date metadata; conflicting provenance is refused. Existing schemas 1–9 migrate with null original dates. Startup and archives validate canonical metadata and the exact schema; forged historical labels are refused.

Scoped event, reference and hit reads return dates from the existing SQL row. No date-only payload lookup is introduced. The existing metadata-row allowance covers that bounded field. Current context selection v3 includes `captured_utc` and `source_time` object/null in recent and historical framing. The actual framed bytes are counted against serialized and provider context limits. Additional framing can reduce the retained recent suffix or delivered evidence at the unchanged caps. Source selection and input receipts bind the date evidence along with original payload identity under the original answering lease. Changes to bound dates invalidate those receipts. Selection v1/v2 retain exact original framing, snapshots and SQL projections.

Lexical hits, semantic hits, following-assistant prefixes and replay retain dates. An indexed `sourceManifest(originalDayRange:)` filters by literal source civil day, preserves source publication order and excludes unknown dates. It is an internal read API. Natural-language queries do not automatically become date filters. The index supplies no universal UTC chronology across unknown or differing offsets.

Backups preserve exact nullable metadata, source payloads and capture times. Genuine old archives restore with unknown dates. Importer sidecars remain outside the application archive; preserve them separately to repeat original-artifact verification. Date provenance in the restored database retains the original hash, pointer and literal.

## Verification boundary

Synthetic checks cover normalization, precision, offsets, Unicode pointer identity, import proof/refusal, full-input prefix validation, atomic publication, retries, scoped day ranges, context delivery, funded receipts, date mutation, legacy replay, restart and archive recovery. These establish metadata integrity and delivery. Representative temporal answer quality, cross-session correction handling and benchmark protocols remain separate work.

Run the isolated date contract with `.build/boros/Boros.app/Contents/MacOS/Boros --source-time-self-test`. The full `scripts/check.py` wave also executes it, native import fixtures, dated context/proof checks and offline restart preservation.
