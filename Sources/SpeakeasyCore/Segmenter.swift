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
        /// The first chunk is smaller, to minimize time to first sound. This is a
        /// latency preference, not a safety invariant: if a single unit alone can't fit
        /// under it (e.g. a hard-split fragment sized to `characterCap`), it is still
        /// emitted as chunk 0 rather than being broken further. `characterCap` is the
        /// only bound that may never be exceeded.
        public var firstChunkCap: Int = 100
        public init() {}
    }

    /// A piece of text destined for a chunk, plus whether a space separates it from
    /// whatever precedes it, wherever it lands.
    ///
    /// `spaced` is false for: the second and later fragments produced by hard-splitting
    /// a single word that alone exceeded the character cap (e.g. a long URL), and for a
    /// clause piece that follows a clause-boundary delimiter (`,` `;` `:`) with no
    /// actual whitespace after it in the source (again, a URL's "https:" is the
    /// motivating case). In both cases there was never a real space at that seam, so
    /// treating it as spaced would insert a character that was never in the input.
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
            if clause.text.count <= options.characterCap {
                pieces.append(clause)
            } else {
                pieces.append(contentsOf: splitAtWordBoundaries(clause.text, leadingSpaced: clause.spaced))
            }
        }
        return pieces
    }

    /// Splits on `,` `;` `:`, keeping the delimiter attached to the piece before it.
    ///
    /// Whether the *next* piece is `spaced` is derived from the source, not assumed: a
    /// comma in prose is almost always followed by a real space ("here, and..."), but a
    /// colon inside a URL ("https://...") is not. Checking the character right after the
    /// delimiter — rather than hard-coding `true` — keeps clause splitting from
    /// fabricating a space that was never in the input.
    private func splitAtClauseBoundaries(_ sentence: String) -> [Unit] {
        var pieces: [Unit] = []
        var current = ""
        var spaced = true
        var index = sentence.startIndex
        while index < sentence.endIndex {
            let character = sentence[index]
            current.append(character)
            if character == "," || character == ";" || character == ":" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    pieces.append(Unit(text: trimmed, spaced: spaced))
                }
                current = ""
                let next = sentence.index(after: index)
                spaced = next < sentence.endIndex && sentence[next].isWhitespace
            }
            index = sentence.index(after: index)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            pieces.append(Unit(text: tail, spaced: spaced))
        }
        return pieces.isEmpty ? [Unit(text: sentence, spaced: true)] : pieces
    }

    /// `leadingSpaced` carries the spacing of the clause this word run came from: the
    /// very first piece this call produces inherits it, since that seam is the clause
    /// boundary handled by the caller. Every later piece within this call is a genuine
    /// interior word-boundary split (on a literal `" "`) or a hard-split continuation, so
    /// its spacing is decided locally.
    private func splitAtWordBoundaries(_ clause: String, leadingSpaced: Bool) -> [Unit] {
        var pieces: [Unit] = []
        var current: [String] = []
        var length = 0

        func flushLine() {
            guard !current.isEmpty else { return }
            let spaced = pieces.isEmpty ? leadingSpaced : true
            pieces.append(Unit(text: current.joined(separator: " "), spaced: spaced))
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
                    let spaced = index == 0 ? (pieces.isEmpty ? leadingSpaced : true) : false
                    pieces.append(Unit(text: fragment, spaced: spaced))
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
        var currentText = ""

        func capForNextChunk() -> Int {
            chunks.isEmpty ? min(options.firstChunkCap, options.characterCap)
                           : options.characterCap
        }

        func emit() {
            guard !currentText.isEmpty else { return }
            chunks.append(Chunk(id: chunks.count,
                                text: currentText,
                                estimatedDuration: estimator.estimate(characterCount: currentText.count)))
            currentText = ""
        }

        for unit in units {
            let wantsSpace = !currentText.isEmpty && unit.spaced
            let cap = capForNextChunk()
            let need = (wantsSpace ? 1 : 0) + unit.text.count

            if currentText.isEmpty || currentText.count + need <= cap {
                // Fits in the chunk being built — or there's nothing to flush and this
                // unit must be placed regardless (the accepted firstChunkCap overflow;
                // characterCap can never be exceeded here since every unit is already
                // sized to fit within it).
                if wantsSpace { currentText += " " }
                currentText += unit.text
                continue
            }

            // Doesn't fit alongside what's already here. Flush first. If a real space
            // belongs between the outgoing text and this unit, don't let it vanish at
            // the seam: attach it wherever there is room, preferring the front of the
            // new chunk (so a clause/sentence boundary like "...it," doesn't end up with
            // a trailing space baked into the outgoing chunk). characterCap outranks
            // this: if neither side has room the space is dropped (cap wins) — this can
            // only happen when both the outgoing chunk and the incoming unit are each
            // already sized exactly to the cap, which is rare.
            let outgoingHadRoomForTrailingSpace = currentText.count + 1 <= cap
            emit()

            guard wantsSpace else {
                currentText = unit.text
                continue
            }
            if 1 + unit.text.count <= options.characterCap {
                currentText = " " + unit.text
            } else if outgoingHadRoomForTrailingSpace, let last = chunks.indices.last {
                let text = chunks[last].text + " "
                chunks[last] = Chunk(id: chunks[last].id,
                                     text: text,
                                     estimatedDuration: estimator.estimate(characterCount: text.count))
                currentText = unit.text
            } else {
                currentText = unit.text
            }
        }
        emit()
        return chunks
    }
}
