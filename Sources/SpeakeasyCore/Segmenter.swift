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
        var units: [String] = []
        for sentence in sentences(in: trimmed) {
            if sentence.count <= options.characterCap {
                units.append(sentence)
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

    /// Clause boundaries first, then words. Never mid-word.
    private func splitOversized(_ sentence: String) -> [String] {
        var pieces: [String] = []
        for clause in splitAtClauseBoundaries(sentence) {
            if clause.count <= options.characterCap {
                pieces.append(clause)
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

    private func splitAtWordBoundaries(_ clause: String) -> [String] {
        var pieces: [String] = []
        var current: [String] = []
        var length = 0
        for word in clause.split(separator: " ").map(String.init) {
            let added = current.isEmpty ? word.count : word.count + 1
            if length + added > options.characterCap, !current.isEmpty {
                pieces.append(current.joined(separator: " "))
                current = [word]
                length = word.count
            } else {
                current.append(word)
                length += added
            }
        }
        if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
        return pieces
    }

    // MARK: - Packing

    private func pack(_ units: [String]) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [String] = []
        var length = 0

        func capForNextChunk() -> Int {
            chunks.isEmpty ? min(options.firstChunkCap, options.characterCap)
                           : options.characterCap
        }

        func flush() {
            guard !current.isEmpty else { return }
            let text = current.joined(separator: " ")
            chunks.append(Chunk(id: chunks.count,
                                text: text,
                                estimatedDuration: estimator.estimate(characterCount: text.count)))
            current = []
            length = 0
        }

        for unit in units {
            let added = current.isEmpty ? unit.count : unit.count + 1
            if length + added > capForNextChunk(), !current.isEmpty {
                flush()
            }
            current.append(unit)
            length += current.count == 1 ? unit.count : unit.count + 1
        }
        flush()
        return chunks
    }
}
