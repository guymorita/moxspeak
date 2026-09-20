import Foundation

/// Strips document formatting so the engine sees prose.
///
/// Scope is deliberately narrow. Kokoro-FastAPI's normalizer already handles numbers,
/// money, times, phone numbers, units, emails, URLs, abbreviations, all-caps runs and
/// version strings. Anything this type does to those is double-normalization.
public struct TextPreparer: Sendable {

    public enum CodeBlockHandling: Sendable {
        case skip
        case announce
        case keep
    }

    public struct Options: Sendable {
        public var stripMarkdown: Bool = true
        public var codeBlocks: CodeBlockHandling = .announce
        public var stripCitationBrackets: Bool = true
        public var rejoinHardWraps: Bool = true
        public var stripEmoji: Bool = true
        public init() {}
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func prepare(_ raw: String) -> String {
        // Line endings first, before anything reasons about lines.
        //
        // Windows, most web forms and plenty of copied documents send CRLF, and a lone
        // CR still turns up from very old Mac files. Every line-anchored rule below, and
        // the whole of `collapseNewlines`, is written against "\n" — and a stray "\r"
        // does not merely survive, it hides: a blank line arriving as "\r" is not empty,
        // so paragraph breaks quietly stop being breaks and the text is read as one
        // sentence. One substitution here, or that bug in every rule separately.
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
                      .replacingOccurrences(of: "\r", with: "\n")

        // Order matters. Code fences are removed before markdown inline syntax so
        // their contents cannot be mangled on the way out.
        text = handleCodeBlocks(in: text)

        // Hyphenation rejoin runs before stripMarkdown, and newline collapse runs
        // after. stripMarkdown's heading/blockquote/list patterns are line-anchored
        // (?m)^...; collapsing newlines first would erase the line starts those
        // patterns need, so only the first line of a multi-line block would ever
        // get stripped.
        if options.rejoinHardWraps {
            text = rejoinHyphenation(text)
        }
        if options.stripMarkdown {
            text = stripMarkdown(text)
        }
        if options.rejoinHardWraps {
            text = collapseNewlines(text)
        }
        if options.stripCitationBrackets {
            text = text.replacing(/\s*\[\d+(?:\s*,\s*\d+)*\]/, with: "")
        }
        if options.stripEmoji {
            text = stripEmoji(text)
        }
        text = stripObjectPlaceholders(text)
        text = normalizePunctuation(text)
        text = restoreMissingSentenceSpaces(text)

        return collapseWhitespace(text)
    }

    // MARK: - Stages

    private func handleCodeBlocks(in text: String) -> String {
        let replacement: String
        switch options.codeBlocks {
        case .keep:  return text
        case .skip:  replacement = " "
        case .announce: replacement = " Code block. "
        }
        return text.replacing(/```[\s\S]*?```/, with: replacement)
    }

    /// "jum-\nped" -> "jumped". Hyphen plus newline is always a PDF wrap artifact.
    /// Newlines otherwise survive this stage; the rest of the rejoin happens in
    /// `collapseNewlines`, after `stripMarkdown` has had a chance to match on
    /// real line starts.
    private func rejoinHyphenation(_ text: String) -> String {
        text.replacing(/(\w)-\n[ \t]*(\w)/) { m in "\(m.1)\(m.2)" }
    }

    /// Turns line breaks into either a space or a sentence boundary, depending on which
    /// one the break actually was.
    ///
    /// ## The bug this replaces
    ///
    /// Every newline used to become a space. That is right for a soft wrap and wrong for
    /// everything else, and web pages are mostly everything else. A heading above a
    /// paragraph, a stack of short marketing lines, a list: all of them ran together into
    /// one breathless sentence, because a line with no full stop at the end of it got
    /// joined to the next line with nothing but a space.
    ///
    ///     For Developers
    ///
    ///     Start with code.
    ///
    /// became "For Developers Start with code." — spoken as a single clause, with the
    /// heading swallowed into the sentence after it. Kokoro cannot put a pause where the
    /// text does not ask for one.
    ///
    /// ## Telling a break from a wrap
    ///
    /// The hard part is that a soft wrap looks identical at the end of the line: both
    /// stop without punctuation. The difference is in what comes next.
    ///
    /// - **A blank line** is always a real break. Nothing wraps across a blank line.
    /// - **A single newline** is a wrap only if the next line continues the sentence,
    ///   and a line that continues a sentence starts in lower case. A next line that
    ///   starts with a capital, a digit or a quote is a new thought: the next heading,
    ///   the next bullet, the next row.
    ///
    /// Getting this backwards in the other direction would be worse than the bug, so the
    /// wrap case is the one that gets the benefit of the doubt: lower case continues,
    /// everything else breaks.
    private func collapseNewlines(_ text: String) -> String {
        var result = ""
        var sawBlankLine = false
        var previousLine = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                // Remember it and move on. A run of blank lines is one break, and a
                // trailing one must not append a stray full stop to the document.
                if !result.isEmpty { sawBlankLine = true }
                continue
            }
            if result.isEmpty {
                result = content
            } else {
                // A blank line is always a real break; nothing wraps across one. Without
                // a blank line, this is a wrap only if the line carries the sentence on,
                // and a line that does so starts in lower case. A capital, a digit or a
                // quote means a new thought: the next heading, bullet or row.
                let continuesSentence = !sawBlankLine
                    && content.first?.isLowercase == true
                // A paragraph break survives as a newline, taking the place of the space
                // that would otherwise join the two. It is the only whitespace in the
                // prepared text that carries meaning: `Segmenter` breaks a chunk there
                // and marks it, and `AudioSeam` gives it a longer pause than a sentence.
                // Without it a new paragraph is acoustically identical to the next
                // sentence, which is exactly how it sounded.
                var separator = Self.separator(after: result, breaking: !continuesSentence)
                if Self.isParagraphBreak(blankLine: sawBlankLine, previousLine: previousLine) {
                    separator = String(separator.dropLast()) + "\n"
                }
                result += separator
                result += content
            }
            sawBlankLine = false
            previousLine = content
        }
        return result
    }

    /// Whether the break before a line separates two paragraphs rather than two sentences.
    ///
    /// A blank line always does; nothing wraps across one. The awkward case is a single
    /// newline, and it matters because that is usually what a browser puts on the
    /// clipboard between two paragraphs. Requiring a blank line meant the paragraph pause
    /// never appeared for the source people actually read from, which is how a fix that
    /// measured correctly in a test still sounded broken in the app.
    ///
    /// Two conditions, both needed:
    ///
    /// - **The previous line finished a sentence.** A line ending mid-sentence is a soft
    ///   wrap, and pausing there would wreck PDFs and email.
    /// - **It was long.** This is what separates a paragraph from a list item or a
    ///   navigation link, which also sit alone on a line and, after `stripMarkdown`
    ///   terminates them, also end in a full stop.
    ///
    /// The cost is that a very short paragraph gets a sentence pause, and prose written
    /// one sentence per line gets paragraph pauses between sentences. Both are mild, and
    /// both are rarer than the case this exists for.
    private static func isParagraphBreak(blankLine: Bool, previousLine: String) -> Bool {
        if blankLine { return true }
        let trimmed = previousLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= paragraphLineLength, let last = trimmed.last else { return false }
        return ".!?\u{2026}".contains(last)
    }

    /// How long a line must be before a single newline after it reads as a paragraph
    /// break rather than a list item. List items and nav links run to a handful of words;
    /// a paragraph of prose runs to several lines' worth.
    private static let paragraphLineLength = 60

    /// What goes between two lines: a space when the first was soft-wrapped, and the
    /// full stop that makes it a sentence of its own when the break was real and the line
    /// did not already end in something a speaker would pause on.
    private static func separator(after line: String, breaking: Bool) -> String {
        guard breaking else { return " " }

        // Closing quotes and brackets sit outside the punctuation they close, so
        // `He said "stop."` is plainly already terminated.
        var tail = Substring(line)
        while let last = tail.last, "\"'\u{2019}\u{201D})]}\u{BB}".contains(last) {
            tail = tail.dropLast()
        }
        // `:` and `;` earn a pause of their own, and a dash ends a deliberately trailing
        // line. A full stop after any of them would read as a stutter.
        if let last = tail.last, ".!?\u{2026}:;\u{2014}-".contains(last) { return " " }
        return ". "
    }

    private func stripMarkdown(_ text: String) -> String {
        var out = text
        // Links and images: keep the label, drop the target.
        out = out.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { m in String(m.1) }
        // Heading hashes at line start.
        out = out.replacing(/(?m)^[ \t]*#{1,6}[ \t]+/, with: "")
        // Blockquote markers at line start.
        out = out.replacing(/(?m)^[ \t]*>[ \t]?/, with: "")
        // List bullets and ordered markers at line start.
        //
        // The marker is also the only surviving evidence that the line is a standalone
        // item, so an item that does not end in punctuation is terminated here, while the
        // bullet is still there to prove it was one. Once the marker is gone the line is
        // indistinguishable from a wrapped fragment, and `collapseNewlines` has to guess
        // from the next line's first letter — which reads "macOS 14 or later" as a
        // continuation, because "macOS" begins in lower case.
        out = out.replacing(/(?m)^[ \t]*(?:[-*+]|\d+\.)[ \t]+([^\n]*)/) { m in
            let item = String(m.1).trimmingCharacters(in: .whitespaces)
            guard let last = item.last else { return item }
            return ".!?\u{2026}:;".contains(last) ? item : item + "."
        }
        // Horizontal rules.
        out = out.replacing(/(?m)^[ \t]*(?:---+|\*\*\*+|___+)[ \t]*$/, with: " ")
        // Inline code.
        out = out.replacing(/`([^`]*)`/) { m in String(m.1) }
        // Emphasis. Longest markers first so ** is consumed before *.
        out = out.replacing(/\*\*\*([^*]+)\*\*\*/) { m in String(m.1) }
        out = out.replacing(/\*\*([^*]+)\*\*/) { m in String(m.1) }
        out = out.replacing(/\*([^*]+)\*/) { m in String(m.1) }
        out = out.replacing(/__([^_]+)__/) { m in String(m.1) }
        // Table pipes.
        out = out.replacing(/[ \t]*\|[ \t]*/, with: " ")
        return out
    }

    private func stripEmoji(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation
              || scalar.properties.isEmojiModifier
              || scalar.properties.isEmojiModifierBase
              || scalar.value == 0x200D
              || scalar.value == 0xFE0F)
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// Removes U+FFFC OBJECT REPLACEMENT CHARACTER.
    ///
    /// Selected text that arrives from a browser carries one of these wherever the
    /// selection crossed something that is not text — an image, a button, or the
    /// invisible anchor link GitHub wraps every markdown heading in, which is how a user
    /// who selects the heading "Read Aloud TTS with Kokoro" ends up holding
    /// "Read Aloud TTS with Kokoro\u{FFFC}".
    ///
    /// It belongs here and not in `SelectionReader` for the same reason every other
    /// stripping rule does: this is the one stage that owns turning a document into
    /// prose. A second stripper growing quietly inside the selection reader is how the
    /// two start disagreeing about what the engine is allowed to see.
    private func stripObjectPlaceholders(_ text: String) -> String {
        text.replacing("\u{FFFC}", with: "")
    }

    /// Puts back the space between two sentences when there is none.
    ///
    /// Reported as an essay that "just kept reading as if there was no period". The
    /// paragraphs had arrived joined with nothing at all between them — "the kitchen.I
    /// knock on the door" — which is what reading a web page through the Accessibility
    /// API can produce when the text of adjacent blocks is concatenated without a
    /// separator. With no space there is no sentence boundary for the segmenter to find
    /// and none for Kokoro to hear, so it reads straight through, and no amount of
    /// tuning the pause between chunks helps because there is only one chunk.
    ///
    /// Narrow on purpose: a lower-case letter, then a terminator, then a capital. That is
    /// the end of a word running into the start of a sentence, and almost nothing else
    /// looks like it. Requiring the lower-case letter is what keeps "U.S.A" and "J.R.R."
    /// intact, since those have a capital on the left. Decimals are untouched because a
    /// digit is not a lower-case letter and a digit is not a capital.
    private func restoreMissingSentenceSpaces(_ text: String) -> String {
        text.replacing(/([a-z])([.!?])([A-Z])/) { match in
            "\(match.1)\(match.2) \(match.3)"
        }
    }

    private func normalizePunctuation(_ text: String) -> String {
        var out = text
        out = out.replacing("\u{2018}", with: "'")
        out = out.replacing("\u{2019}", with: "'")
        out = out.replacing("\u{201C}", with: "\"")
        out = out.replacing("\u{201D}", with: "\"")
        out = out.replacing("\u{2026}", with: "...")
        out = out.replacing("\u{2014}", with: " - ")
        out = out.replacing("\u{2013}", with: "-")
        return out
    }

    /// Runs of spaces become one space. Newlines are left alone: by this point the only
    /// ones left are paragraph breaks, put there deliberately by `collapseNewlines`, and
    /// collapsing them would throw away the distinction it exists to preserve.
    private func collapseWhitespace(_ text: String) -> String {
        text.replacing(/[ \t\u{00A0}]+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
