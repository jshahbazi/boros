import Foundation

enum HistoricalQueryChecks {
    static func run() -> [String: Bool] {
        func query(_ text: String) -> HistoricalQueryFormulation.Result { HistoricalQueryFormulation.formulate(text) }
        let plain = query("Please tell me about Alpha alpha café e\u{301} 日本語 snake_case 42 omega beta gamma delta")
        let anchor = query("Quote exactly first nonempty line trim whitespace reply earlier message starts with \"rivet copper lattice mercury quartz spruce\" return JSON answer citations abstain")
        let paired = query("Recover \"alpha beta gamma delta epsilon zeta\" and \"one two three four five six\" exactly")
        let escaped = query("Find \"alpha \\\"beta\\\" gamma\" tail")
        let curly = query("Recall “café e\u{301} 日本語” then `rivet copper`")
        let unmatched = query("Find \"unfinished alpha beta")
        let long = query("\"" + String(repeating: "x", count: 16_385) + "\" fallback value")
        let tooLongTerm = query("\"" + String(repeating: "z", count: 129) + " rivet copper\" fallback")
        let capped = query((0..<12).map { "\"anchor\($0)\"" }.joined(separator: " "))
        let nearByteCap = query((0..<8).map { String(repeating: String(Unicode.Scalar(97 + $0)!), count: 128) }.joined(separator: " ") + " short")
        let cases = [plain, anchor, paired, escaped, curly, unmatched, long, tooLongTerm, capped, nearByteCap]
        let prefix = "Question Date: 2023/05/23 (Tue) 11:23\nQuestion: "
        let natural = "Recall cobalt lattice café κ copper spruce mercury quartz"
        let accepted = prefix + natural, range = prefix.utf8.count..<((prefix + natural).utf8.count)
        func refused(_ span: Range<Int>) -> Bool {
            do { _ = try HistoricalQueryFormulation.input(accepted, utf8Range: span); return false } catch { return true }
        }
        let derived = try? HistoricalQueryFormulation.input(accepted, utf8Range: range)
        let scalar = "κ".utf8.count
        return [
            "query_plain_prefix_and_foundation_unicode_ordinals_preserved": plain.query == "alpha café e\u{301} 日本語 snake case 42 omega"
                && plain.selectedTokenIndices == [4, 6, 7, 8, 9, 10, 11, 12] && plain.quotedAnchorCount == 0,
            "query_source_anchor_precedes_answer_format_prose": anchor.query == "rivet copper lattice mercury quartz spruce quote exactly"
                && anchor.selectedTokenIndices == [12, 13, 14, 15, 16, 17, 0, 1] && anchor.quotedAnchorCount == 1,
            "query_multiple_anchors_share_term_allowance": paired.query == "alpha one beta two gamma three delta four"
                && paired.selectedTokenIndices == [1, 8, 2, 9, 3, 10, 4, 11] && paired.quotedAnchorCount == 2,
            "query_escaped_delimiters_do_not_split_anchor": escaped.query == "alpha beta gamma find tail"
                && escaped.selectedTokenIndices == [1, 2, 3, 0, 4] && escaped.quotedAnchorCount == 1,
            "query_curly_and_backtick_quotes_keep_unicode_terms": curly.query == "café rivet e\u{301} copper 日本語 recall"
                && curly.selectedTokenIndices == [1, 5, 2, 6, 3, 0] && curly.quotedAnchorCount == 2,
            "query_unmatched_quote_uses_prefix_fallback": unmatched.query == "find unfinished alpha beta"
                && unmatched.quotedAnchorCount == 0,
            "query_oversized_anchor_is_not_prioritized": long.query == "fallback value" && long.quotedAnchorCount == 0,
            "query_oversized_term_is_skipped_within_anchor": tooLongTerm.query == "rivet copper fallback"
                && tooLongTerm.selectedTokenIndices == [1, 2, 3],
            "query_anchor_metadata_and_term_count_are_bounded": capped.quotedAnchorCount == 8
                && capped.query == (0..<8).map { "anchor\($0)" }.joined(separator: " "),
            "query_existing_utf8_and_term_limits_remain": cases.allSatisfy {
                ($0.query?.utf8.count ?? 0) <= 1024 && $0.selectedTokenIndices.count <= 8
                    && ($0.query ?? "").split(separator: " ").allSatisfy { $0.utf8.count <= 128 }
            } && nearByteCap.selectedTokenIndices == [0, 1, 2, 3, 4, 5, 6, 8],
            "query_no_literal_terms_returns_nil": query("the and please").query == nil,
            "query_duplicate_anchor_terms_do_not_waste_slots": query("\"alpha alpha beta\" \"ALPHA gamma delta\"").query == "alpha gamma beta delta",
            "query_quote_operators_are_plain_terms": query("Find \"OR NEAR(foo) NOT bar *\"").query == "near foo bar find",
             "query_explicit_range_uses_exact_natural_text": derived == natural
                && query(derived ?? "").query == query(natural).query && query(accepted).query != query(natural).query,
             "query_no_range_retains_full_accepted_text": (try? HistoricalQueryFormulation.input(accepted, utf8Range: nil)) == accepted,
             "query_negative_empty_and_overflow_ranges_refused": refused(-1..<1) && refused(0..<0)
                && refused(0..<(accepted.utf8.count + 1)),
             "query_non_scalar_utf8_boundaries_refused": (try? HistoricalQueryFormulation.input("κx", utf8Range: 1..<scalar)) == nil
                && (try? HistoricalQueryFormulation.input("κx", utf8Range: 0..<1)) == nil,
             "query_unicode_and_nul_bytes_are_preserved": (try? HistoricalQueryFormulation.input("headκ\0e\u{301}tail",
                utf8Range: 4..<(4 + "κ\0e\u{301}".utf8.count))) == "κ\0e\u{301}"
        ]
    }
}
