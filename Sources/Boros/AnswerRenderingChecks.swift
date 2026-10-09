import AppKit

/// Synthetic contracts for display-only answer rendering (fix E). They report
/// fixed check names and booleans only; no stored history is read.
enum AnswerRenderingChecks {
    private static func render(_ text: String) -> NSAttributedString { AnswerRendering.markdown(text) }

    private static func font(_ text: NSAttributedString, _ index: Int) -> NSFont? {
        index < text.length ? text.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
    }

    private static func traits(_ text: NSAttributedString, _ index: Int) -> NSFontTraitMask {
        font(text, index).map { NSFontManager.shared.traits(of: $0) } ?? []
    }

    private static func paragraph(_ text: NSAttributedString, _ index: Int) -> NSParagraphStyle? {
        index < text.length ? text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle : nil
    }

    private static func index(_ text: NSAttributedString, of needle: String) -> Int {
        (text.string as NSString).range(of: needle).location
    }

    private static func hasAttribute(_ key: NSAttributedString.Key, in text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length), options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private static func hasRemoteCapableAttribute(_ text: NSAttributedString) -> Bool {
        hasAttribute(.link, in: text) || hasAttribute(.attachment, in: text)
    }

    private static func full(_ text: NSAttributedString) -> NSRange { NSRange(location: 0, length: text.length) }

    /// The complete original text recovered from a displayed message.
    private static func roundTrip(_ source: String) -> Bool {
        let message = AnswerRendering.message(source, assistant: true, rendered: true, rawAttributes: [:])
        let stored = (message.attribute(.borosMessageSource, at: 0, effectiveRange: nil) as? TranscriptMessageSource)?.text
        return stored.map { Data($0.utf8) == Data(source.utf8) } == true
            && Data(AnswerRendering.originalText(in: full(message), of: message).utf8) == Data(source.utf8)
    }

    static func syntheticAnswer(sections: Int) -> String {
        (0..<sections).map { index in
            "## Section \(index)\n\nThis is **bold \(index)** and *italic* text with `code \(index)`, "
                + "$\\frac{\(index)}{2} \\times 3$, $20 and $30 [E\(index + 1)].\n\n- item one\n  - nested **two**\n"
                + "1. first\n2. second\n\n> quoted line \(index)\n\n```swift\nlet value\(index) = \(index)\n```\n\n"
                + "| a | b |\n|---|---|\n| \(index) | x |\n"
        }.joined(separator: "\n")
    }

    private static func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Render and layout timings for synthetic answers (seconds).
    static func benchmark() -> [String: Double] {
        var result: [String: Double] = [:]
        for sections in [10, 100, 850] {
            let answer = syntheticAnswer(sections: sections)
            var rendered = NSAttributedString()
            result["render_\(answer.utf16.count)_units_seconds"] = seconds { rendered = render(answer) }
            let view = TranscriptTextView(usingTextLayoutManager: false)
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            view.textContainer?.widthTracksTextView = true
            view.textStorage?.setAttributedString(rendered)
            result["layout_\(answer.utf16.count)_units_seconds"] = seconds {
                view.layoutManager?.ensureLayout(for: view.textContainer!)
            }
        }
        let oversized = String(repeating: "**plain** fallback line\n", count: AnswerRendering.maximumMarkdownUnits / 24 + 10)
        result["render_oversized_\(oversized.utf16.count)_units_seconds"] = seconds { _ = render(oversized) }
        return result
    }

    static func run() -> [String: Bool] {
        var checks: [String: Bool] = [:]

        // Inline constructs.
        let bold = render("**bold** text")
        checks["render_bold"] = bold.string == "bold text" && traits(bold, 0).contains(.boldFontMask)
            && !traits(bold, 6).contains(.boldFontMask)
        let italic = render("*one* and _two_")
        checks["render_italic"] = italic.string == "one and two" && traits(italic, 0).contains(.italicFontMask)
            && traits(italic, 8).contains(.italicFontMask) && !traits(italic, 4).contains(.italicFontMask)
        let both = render("***both***")
        checks["render_bold_italic"] = both.string == "both" && traits(both, 0).contains(.boldFontMask)
            && traits(both, 0).contains(.italicFontMask)
        checks["render_intraword_underscore_literal"] = render("call snake_case_name now").string == "call snake_case_name now"
        let strike = render("~~gone~~ but ~5 to ~10 stays")
        checks["render_strikethrough_double_tilde_only"] = strike.string == "gone but ~5 to ~10 stays"
            && strike.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
            && strike.attribute(.strikethroughStyle, at: 10, effectiveRange: nil) == nil
        let code = render("Use `a*b*` here")
        checks["render_inline_code_is_literal_monospaced"] = code.string == "Use a*b* here"
            && font(code, 4)?.isFixedPitch == true && !traits(code, 5).contains(.italicFontMask)
            && code.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil
        let escaped = render("\\*not italic\\* and \\#5")
        checks["render_backslash_escapes"] = escaped.string == "*not italic* and #5"
        let lines = render("first line\nsecond line")
        checks["render_soft_breaks_kept_as_line_breaks"] = lines.string == "first line\u{2028}second line"

        // Blocks.
        let fenced = render("Before\n\n```swift\nlet x = 1\n  indented()\n```\nAfter")
        let codeIndex = index(fenced, of: "let x = 1")
        checks["render_fenced_code_block"] = fenced.string == "Before\nlet x = 1\n  indented()\nAfter"
            && font(fenced, codeIndex)?.isFixedPitch == true
            && paragraph(fenced, codeIndex)?.textBlocks.first?.backgroundColor != nil
            && !fenced.string.contains("```") && !fenced.string.contains("swift")
        let tilde = render("~~~\n**raw**\n~~~")
        checks["render_tilde_fence_keeps_markup_literal"] = tilde.string == "**raw**" && font(tilde, 0)?.isFixedPitch == true
        let unclosed = render("```\ncode to end\n# not heading")
        checks["render_unclosed_fence_runs_to_end"] = unclosed.string == "code to end\n# not heading"
        let indented = render("Text\n\n    indented code\n\nMore")
        checks["render_indented_code_block"] = indented.string == "Text\nindented code\nMore"
            && font(indented, index(indented, of: "indented"))?.isFixedPitch == true
        let headings = render("# Title\n## Sub **bold**\n###### Six ###\n#nohash")
        checks["render_headings"] = headings.string == "Title\nSub bold\nSix\n#nohash"
            && (font(headings, 0)?.pointSize ?? 0) > (font(headings, 6)?.pointSize ?? 99)
            && traits(headings, 0).contains(.boldFontMask) && (font(headings, 0)?.pointSize ?? 0) > AnswerRendering.bodySize
        let bullets = render("- one\n- two\n* three")
        checks["render_unordered_list"] = bullets.string == "\u{2022}\tone\n\u{2022}\ttwo\n\u{2022}\tthree"
            && (paragraph(bullets, 0)?.headIndent ?? 0) > 0
        let nested = render("- outer\n  - inner\n    - deepest\n- back")
        let innerIndex = index(nested, of: "inner")
        checks["render_nested_unordered_list"] = nested.string == "\u{2022}\touter\n\u{25E6}\tinner\n\u{25AA}\tdeepest\n\u{2022}\tback"
            && (paragraph(nested, innerIndex)?.headIndent ?? 0) > (paragraph(nested, 0)?.headIndent ?? 0)
        let ordered = render("1. first\n2. second\n10. tenth")
        checks["render_ordered_list_keeps_source_numbers"] = ordered.string == "1.\tfirst\n2.\tsecond\n10.\ttenth"
        let mixed = render("1. Step **one**\n   - detail a\n   - detail b\n2. Step two\n  - lenient child")
        checks["render_mixed_nested_lists"] = mixed.string
            == "1.\tStep one\n\u{25E6}\tdetail a\n\u{25E6}\tdetail b\n2.\tStep two\n\u{25E6}\tlenient child"
        let loose = render("- a\n\n- b\n\n  continued\n\nafter")
        checks["render_loose_list_continuation"] = loose.string == "\u{2022}\ta\n\u{2022}\tb\ncontinued\nafter"
        checks["render_year_line_not_list_inside_paragraph"] = render("The year was\n2020. Then more").string
            == "The year was\u{2028}2020. Then more"
        let quote = render("> quoted **text**\n> second\n\nafter")
        checks["render_block_quote"] = quote.string == "quoted text\u{2028}second\nafter"
            && (quote.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == NSColor.secondaryLabelColor
            && paragraph(quote, 0)?.textBlocks.count == 1 && paragraph(quote, quote.length - 1)?.textBlocks.isEmpty == true
        let nestedQuote = render("> outer\n>> inner")
        checks["render_nested_block_quote"] = nestedQuote.string == "outer\ninner"
            && paragraph(nestedQuote, index(nestedQuote, of: "inner"))?.textBlocks.count == 2
        let rule = render("above\n\n---\n\nbelow")
        checks["render_thematic_break"] = rule.string == "above\n \nbelow"
            && paragraph(rule, 6)?.textBlocks.first.map { $0.width(for: .border, edge: .maxY) } == 1
        let table = render("| Name | Value |\n|:---|---:|\n| **a** | `1` |\n| b |\n\nafter")
        let tableBlock = paragraph(table, 0)?.textBlocks.last as? NSTextTableBlock
        checks["render_table"] = table.string == "Name\nValue\na\n1\nb\n\nafter"
            && tableBlock?.table.numberOfColumns == 2 && traits(table, 0).contains(.boldFontMask)
            && paragraph(table, index(table, of: "Value"))?.alignment == .right
            && traits(table, index(table, of: "a\n1")).contains(.boldFontMask)
        checks["render_table_requires_matching_delimiter_row"] = render("| a | b |\n|---|\n| 1 | 2 |").string
            == "| a | b |\u{2028}|---|\u{2028}| 1 | 2 |"

        // Text blocks and tables fill the available width instead of shrinking to one glyph per line.
        let layoutView = TranscriptTextView(usingTextLayoutManager: false)
        layoutView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        layoutView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        func height(_ source: String) -> CGFloat {
            layoutView.textStorage?.setAttributedString(render(source))
            layoutView.layoutManager?.ensureLayout(for: layoutView.textContainer!)
            return layoutView.layoutManager?.usedRect(for: layoutView.textContainer!).height ?? .infinity
        }
        checks["layout_blocks_use_available_width"] = height("> a quoted line of ordinary length") < 60
            && height("```\nlet value = 1 // a code line of ordinary length\n```") < 60
            && height("| Name | Value |\n|---|---|\n| ordinary | width |") < 90
            && height("- item\n  > nested quote inside a list item of ordinary length") < 80

        // Links and untrusted content.
        let link = render("Read [the guide](https://example.com/guide?a=1 \"Title\") now")
        let linkIndex = index(link, of: "the guide")
        checks["render_http_link_is_explicit_click_target"] = link.string == "Read the guide now"
            && (link.attribute(.borosLink, at: linkIndex, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/guide?a=1"
            && link.attribute(.toolTip, at: linkIndex, effectiveRange: nil) as? String == "https://example.com/guide?a=1"
            && !hasAttribute(.link, in: link)
        let auto = render("See <https://example.com/x> and https://example.org bare")
        checks["render_autolink_only_in_angle_brackets"] = auto.string == "See https://example.com/x and https://example.org bare"
            && auto.attribute(.borosLink, at: 4, effectiveRange: nil) != nil
            && auto.attribute(.borosLink, at: index(auto, of: "example.org"), effectiveRange: nil) == nil
        let unsafe = ["[x](javascript:alert(1))", "[x](file:///etc/hosts)", "[x](data:text/html,hi)",
                      "[x](https://user:secret@example.com)", "[x](mailto:someone@example.com)", "[x](//example.com)",
                      "[x](ftp://example.com)", "<javascript:alert(1)>", "[x](<https://exa mple.com>)"]
        checks["render_unsafe_link_schemes_stay_literal"] = unsafe.allSatisfy { source in
            let rendered = render(source)
            return rendered.string == source && !hasAttribute(.borosLink, in: rendered)
        }
        let image = render("![chart](https://example.com/chart.png) and ![x](file:///tmp/a.png)")
        checks["render_images_never_load"] = image.string == "![chart](https://example.com/chart.png) and ![x](file:///tmp/a.png)"
            && !hasAttribute(.borosLink, in: image) && !hasRemoteCapableAttribute(image)
        let html = "<script>alert(1)</script> <img src=\"https://example.com/a.png\"> <b>x</b>"
        checks["render_html_is_literal_text"] = render(html).string == html
        let safe = ["https://example.com", "http://example.com/a(b)", "HTTPS://Example.com/path"]
        let refused = ["javascript:alert(1)", "file:///etc/hosts", "https://", "https://u:p@example.com",
                       "https://exa mple.com", "https://example.com/\u{0007}", "data:text/plain,x", "example.com", ""]
        checks["safe_link_url_allowlist"] = safe.allSatisfy { AnswerRendering.safeLinkURL($0) != nil }
            && refused.allSatisfy { AnswerRendering.safeLinkURL($0) == nil }

        // Citation labels stay literal and never become link references.
        let citations = ["Supported by [E1].", "See [E1] and [E2][E3].", "Both [E1, E2] agree.", "[E12][E1]",
                         "[E1](https://example.com/evidence)", "[E1](E2)", "[E1] (see above)", "Use [E1][ref] here.",
                         "[E1, E2](https://example.com)"]
        checks["citation_labels_render_unchanged"] = citations.allSatisfy { source in
            let rendered = render(source)
            return rendered.string == source && !hasAttribute(.borosLink, in: rendered)
        }
        let definition = render("[E1]: https://example.com/evidence\n\nUse [E1] and [ref].\n\n[ref]: https://example.com")
        checks["reference_definitions_not_resolved"] = definition.string
            == "[E1]: https://example.com/evidence\nUse [E1] and [ref].\n[ref]: https://example.com"
            && !hasAttribute(.borosLink, in: definition)
        checks["citation_label_detector"] = AnswerRendering.isCitationLabel(Array("E1".utf16)[...])
            && AnswerRendering.isCitationLabel(Array("E1, E23".utf16)[...])
            && !AnswerRendering.isCitationLabel(Array("E0".utf16)[...]) && !AnswerRendering.isCitationLabel(Array("guide".utf16)[...])
            && !AnswerRendering.isCitationLabel(Array("".utf16)[...])

        // Math heuristic.
        let times = render("So $2 \\times 3 = 6$ holds")
        let mathIndex = index(times, of: "2 \u{00D7} 3 = 6")
        checks["math_inline_times_rendered"] = times.string == "So 2 \u{00D7} 3 = 6 holds"
            && font(times, mathIndex)?.fontName != font(times, 0)?.fontName
        checks["math_frac_and_cdot"] = render("$\\frac{a}{b}$, $\\frac{a+1}{2b}$ and $a \\cdot b$").string
            == "a/b, (a+1)/(2b) and a \u{00B7} b"
        let scripts = render("$x^2 + a_i$ and $e^{i\\pi}$")
        checks["math_scripts_use_baseline_offsets"] = scripts.string == "x2 + ai and ei\u{03C0}"
            && (scripts.attribute(.baselineOffset, at: 1, effectiveRange: nil) as? CGFloat ?? 0) > 0
            && (scripts.attribute(.baselineOffset, at: 6, effectiveRange: nil) as? CGFloat ?? 0) < 0
            && (font(scripts, 1)?.pointSize ?? 99) < (font(scripts, 0)?.pointSize ?? 0)
        checks["math_common_commands"] = render("$\\alpha \\le \\beta \\neq \\infty$ and $\\sqrt{x+1}$ and $\\text{total} = 5$").string
            == "\u{03B1} \u{2264} \u{03B2} \u{2260} \u{221E} and \u{221A}(x+1) and total = 5"
        checks["math_unknown_command_literal"] = render("$\\weird{x}$").string == "\\weirdx"
        let display = render("Result:\n\n$$E = mc^2$$\n\nDone")
        checks["math_display_dollars_centered"] = display.string == "Result:\nE = mc2\nDone"
            && paragraph(display, index(display, of: "E = mc"))?.alignment == .center
        checks["math_latex_delimiters"] = render("Inline \\(x+1\\) and \\[y\\]").string == "Inline x+1 and y"
        let money = ["$20 and $30", "It costs $5, $10, and $15.", "US$5 or US$7", "$1,000-$2,000",
                     "$5 per month, i.e. 60$ per year", "Between $20 and $30 or 5$", "Pay $20 (about $25) today",
                     "A $ sign alone", "Cost: $ 5$", "Totals $12.50/$13.75", "$$ is slang"]
        checks["math_dollar_amounts_untouched"] = money.allSatisfy { render($0).string == $0 }
        checks["math_escaped_dollars_literal"] = render("\\$5 and \\$x\\$").string == "$5 and $x$"
        checks["math_not_inside_code"] = render("`$x$` and $x$").string == "$x$ and x"
        checks["math_single_dollar_does_not_cross_lines"] = render("from $a\nto b$").string == "from $a\u{2028}to b$"
        checks["math_bounded_length"] = render("$" + String(repeating: "x", count: AnswerRendering.maximumInlineMathUnits + 5) + "$")
            .string.hasPrefix("$")

        // Original text is never altered.
        let fidelity = ["**Bold** text", "## H\r\n\r\n- a\r\n- b\r\n", "cafe\u{301} 👩‍👩‍👧 $x$\n", "\n\n  leading and trailing  \n\n",
                        "```\nfenced at start\n```", "> q\n>\n> r", "| a |\n|---|\n| é |", "[E1](https://example.com) `x`",
                        "trailing backslash \\", "tabs\tand\u{2028}separators", "$$\\frac{1}{2}$$"]
        checks["rendering_preserves_exact_original_text"] = fidelity.allSatisfy(roundTrip)
        let partial = AnswerRendering.message("**Bold** text and $x^2$ end", assistant: true, rendered: true, rawAttributes: [:])
        let rendered = partial.string as NSString
        checks["original_text_maps_partial_selections"] =
            AnswerRendering.originalText(in: rendered.range(of: "old"), of: partial) == "old"
            && AnswerRendering.originalText(in: rendered.range(of: "text"), of: partial) == "text"
            && AnswerRendering.originalText(in: rendered.range(of: "x2"), of: partial) == "$x^2$"
            && AnswerRendering.originalText(in: NSRange(location: 0, length: 4), of: partial) == "**Bold"
            && AnswerRendering.originalText(in: NSRange(location: rendered.length - 3, length: 3), of: partial) == "end"
        let raw = "**raw** $x$ [E1]\n"
        let rawMessage = AnswerRendering.message(raw, assistant: true, rendered: false,
                                                 rawAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        checks["original_text_mode_displays_exact_bytes"] = rawMessage.string == raw && font(rawMessage, 0)?.isFixedPitch == true
        checks["human_text_never_parsed"] = AnswerRendering.message(raw, assistant: false, rendered: true, rawAttributes: [:]).string == raw

        // Copy writes the original text through the transcript view.
        let view = TranscriptTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let transcript = NSMutableAttributedString(string: "Assistant\n")
        let answer = "# Plan\n\n1. **Step** one costs $20 and $30\n2. Run `make`\n"
        transcript.append(AnswerRendering.message(answer, assistant: true, rendered: true, rawAttributes: [:]))
        transcript.append(NSAttributedString(string: "\n\n"))
        view.textStorage?.setAttributedString(transcript)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.boros.rendering-checks." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        view.setSelectedRange(NSRange(location: 0, length: transcript.length))
        let wroteAll = view.writeSelection(to: pasteboard, types: [.string])
        checks["copy_whole_transcript_gives_original_text"] = wroteAll
            && pasteboard.string(forType: .string) == "Assistant\n" + answer + "\n\n"
        let stepRange = (view.string as NSString).range(of: "Step one")
        view.setSelectedRange(stepRange)
        _ = view.writeSelection(to: pasteboard, types: [.string])
        checks["copy_partial_selection_gives_original_span"] = pasteboard.string(forType: .string) == "Step** one"
        checks["copy_offers_plain_text_only"] = view.writablePasteboardTypes == [.string]

        // Malformed and adversarial input degrades to literal text without loss.
        var generator: UInt64 = 0x9E3779B97F4A7C15
        let alphabet = Array("*_`~$[]()<>!#|-+>:\\ \n\tabcE1é{}^")
        var fuzz: [String] = []
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<120 {
                generator = generator &* 6364136223846793005 &+ 1442695040888963407
                text.append(alphabet[Int(generator >> 33) % alphabet.count])
            }
            fuzz.append(text)
        }
        let malformed = ["**bold", "`code", "[link](", "[link](https://example.com", "| a |\n|--", "***", "$", "$$", "\\",
                         "```", "~~~", "<", "![", "1.", "- ", ">", "#", "|", "* * *\n- - -", "__a**b__c**",
                         String(repeating: ">", count: 200) + " deep", String(repeating: "[", count: 5000),
                         String(repeating: "*a", count: 5000), String(repeating: "`", count: 3000) + "x",
                         (0..<60).map { String(repeating: "  ", count: $0) + "- level" }.joined(separator: "\n"),
                         String(repeating: "$x", count: 3000), String(repeating: "\\(", count: 2000)]
        checks["malformed_input_round_trips"] = (malformed + fuzz).allSatisfy(roundTrip)
        checks["malformed_input_never_empty"] = (malformed + fuzz).allSatisfy { !render($0).string.isEmpty }
        checks["deep_nesting_falls_back_to_plain"] = render(String(repeating: ">", count: 200) + " deep").string.contains("deep")
        let samples = citations + unsafe + money + malformed + fidelity + [html, "![a](https://example.com/a.png)", syntheticAnswer(sections: 3)]
        checks["no_remote_capable_attributes"] = samples.allSatisfy { !hasRemoteCapableAttribute(render($0)) }

        // Performance bounds on synthetic answers.
        let large = syntheticAnswer(sections: 850)
        var largeRendered = NSAttributedString()
        let largeSeconds = seconds { largeRendered = render(large) }
        checks["performance_large_answer_renders_within_bound"] = large.utf16.count > 200_000 && largeSeconds < 2.0
            && roundTrip(String(large.prefix(20_000)))
        checks["performance_large_answer_fully_rendered"] = !largeRendered.string.contains("**")
        let oversized = String(repeating: "**plain** fallback line\n", count: AnswerRendering.maximumMarkdownUnits / 24 + 10)
        var oversizedRendered = NSAttributedString()
        let oversizedSeconds = seconds { oversizedRendered = render(oversized) }
        checks["performance_oversized_answer_falls_back_to_plain"] = oversizedRendered.string == oversized && oversizedSeconds < 1.0
        let adversarial = String(repeating: "*a _b [c `d $e ", count: 20_000)
        checks["performance_adversarial_delimiters_bounded"] = seconds { _ = render(adversarial) } < 2.0
        return checks
    }
}
