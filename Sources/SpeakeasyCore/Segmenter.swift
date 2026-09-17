import Foundation
import NaturalLanguage

/// Splits prepared text into chunks small enough to synthesize quickly and reliably.
///
/// The character cap is the governing constraint, not the sentence boundary. A single
/// sentence can run to thousands of characters, and the backend loses audio above
/// roughly 180 characters (see the spec's Known Issues), so sentence-sized chunks are
/// unsafe on both counts.
public struct Segmenter: Sendable {

    public struct Options: Sendable {
        /// Hard maximum. No chunk may exceed this.
        public var characterCap: Int = 150
        /// The first chunk is smaller, to minimize time to first sound.
        public var firstChunkCap: Int = 100
        public init() {}
    }

    /// A piece of text destined for a chunk, plus whether a space separates it from
    /// whatever precedes it in the same chunk.
    ///
    /// `spaced` is false only for the second and later fragments produced by
    /// hard-splitting a single word that alone exceeded the character cap (e.g. a long
    /// URL). Those fragments were never separated by whitespace in the source, so
    /// rejoining them with a space would insert a character that was never there.
    private struct Unit {
        let text: String
        let spaced: Bool
    }

    private let options: Options
    private let estimator: DurationEstimator

    public init(options: Options = Options(),
                estimator: DurationEstimator = DurationEstimator()) {
        self.options = options
        self.estimator = estimator
    }

    public func segment(_ text: String) -> [Chunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Units are sentences; anything over the cap is pre-split into clause or word
        // pieces so the packer only ever sees things that fit.
        var units: [Unit] = []
        for sentence in sentences(in: trimmed) {
            if sentence.count <= options.characterCap {
                units.append(Unit(text: sentence, spaced: true))
            } else {
                units.append(contentsOf: splitOversized(sentence))
            }
        }

        return pack(units)
    }

    // MARK: - Sentence detection

    private func sentences(in text: String) -> [String] {
        // NLTokenizer knows that "Dr." is not a sentence end.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    // MARK: - Oversized sentence handling

    /// Clause boundaries first, then words. Never mid-word — unless a single word alone
    /// exceeds the cap, in which case the cap wins (see `splitAtWordBoundaries`).
    private func splitOversized(_ sentence: String) -> [Unit] {
        var pieces: [Unit] = []
        for clause in splitAtClauseBoundaries(sentence) {
            if clause.count <= options.characterCap {
                pieces.append(Unit(text: clause, spaced: true))
            } else {
                pieces.append(contentsOf: splitAtWordBoundaries(clause))
            }
        }
        return pieces
    }

    private func splitAtClauseBoundaries(_ sentence: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in sentence {
            current.append(character)
            if character == "," || character == ";" || character == ":" {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.isEmpty ? [sentence] : pieces
    }

    private func splitAtWordBoundaries(_ clause: String) -> [Unit] {
        var pieces: [Unit] = []
        var current: [String] = []
        var length = 0

        func flushLine() {
            guard !current.isEmpty else { return }
            pieces.append(Unit(text: current.joined(separator: " "), spaced: true))
            current = []
            length = 0
        }

        for word in clause.split(separator: " ").map(String.init) {
            if word.count > options.characterCap {
                // A single word longer than the cap can't be emitted whole: the cap is
                // the hard constraint (silent audio loss above it), so it wins over
                // "never split mid-word" for this one pathological case. Split on
                // Character boundaries so multi-byte grapheme clusters are never torn.
                flushLine()
                for (index, fragment) in hardSplit(word).enumerated() {
                    pieces.append(Unit(text: fragment, spaced: index == 0))
                }
                continue
            }
            let added = current.isEmpty ? word.count : word.count + 1
            if length + added > options.characterCap, !current.isEmpty {
                flushLine()
                current = [word]
                length = word.count
            } else {
                current.append(word)
                length += added
            }
        }
        flushLine()
        return pieces
    }

    /// Splits a single overlong word into `characterCap`-sized fragments, iterating by
    /// `Character` (extended grapheme cluster) rather than byte or Unicode scalar, so a
    /// multi-byte character is never torn across two fragments.
    private func hardSplit(_ word: String) -> [String] {
        var fragments: [String] = []
        var current = ""
        var count = 0
        for character in word {
            current.append(character)
            count += 1
            if count == options.characterCap {
                fragments.append(current)
                current = ""
                count = 0
            }
        }
        if !current.isEmpty { fragments.append(current) }
        return fragments
    }

    // MARK: - Packing

    private func pack(_ units: [Unit]) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [Unit] = []
        var length = 0

        func capForNextChunk() -> Int {
            chunks.isEmpty ? min(options.firstChunkCap, options.characterCap)
                           : options.characterCap
        }

        func flush() {
            guard !current.isEmpty else { return }
            var text = ""
            for unit in current {
                if !text.isEmpty && unit.spaced { text += " " }
                text += unit.text
            }
            chunks.append(Chunk(id: chunks.count,
                                text: text,
                                estimatedDuration: estimator.estimate(characterCount: text.count)))
            current = []
            length = 0
        }

        for unit in units {
            let addsSpaceIfAppended = !current.isEmpty && unit.spaced
            let added = unit.text.count + (addsSpaceIfAppended ? 1 : 0)
            if length + added > capForNextChunk(), !current.isEmpty {
                flush()
            }
            // Recompute after a possible flush: `current` may now be empty, which
            // changes whether this unit picks up a leading space.
            let addsSpace = !current.isEmpty && unit.spaced
            current.append(unit)
            length += unit.text.count + (addsSpace ? 1 : 0)
        }
        flush()
        return chunks
    }
}
