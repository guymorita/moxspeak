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
        var text = raw

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
        text = normalizePunctuation(text)

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

    /// Blank-line paragraph breaks and single soft-wrap newlines both become a
    /// single space.
    private func collapseNewlines(_ text: String) -> String {
        var out = text
        // Blank line means paragraph break: becomes a space, sentence punctuation stays.
        out = out.replacing(/\n[ \t]*\n[\s]*/, with: " ")
        // A single newline inside a paragraph is a soft wrap.
        out = out.replacing(/\n[ \t]*/, with: " ")
        return out
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
        out = out.replacing(/(?m)^[ \t]*(?:[-*+]|\d+\.)[ \t]+/, with: "")
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

    private func collapseWhitespace(_ text: String) -> String {
        text.replacing(/[ \t\u{00A0}]+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
