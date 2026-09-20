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

        /// Builds options from a provider's declared `SpeechProvider.recommendedCharacterCap`.
        ///
        /// `characterCap` becomes the provider's number directly — it's a provider-owned
        /// hard bound (150 for the HTTP provider's PyTorch-MPS truncation workaround, 100
        /// measured for the native engine's memory/sentence-length tradeoff).
        ///
        /// `firstChunkCap` governs time-to-first-sound and stays at its latency-tuned
        /// default UNLESS the provider's cap is smaller, in which case it is clamped down
        /// to match. `pack()` would already produce the same result on its own — chunk 0's
        /// cap there is `min(firstChunkCap, characterCap)` — but leaving the relationship
        /// to be rediscovered three fields away, inside packing logic, means a provider
        /// declaring an unusually small cap only behaves correctly by accident. Clamping
        /// here makes "firstChunkCap can lower, never raise, and never exceed
        /// characterCap" a property of construction instead of an implicit consequence.
        public init(providerCap: Int) {
            self.characterCap = providerCap
            self.firstChunkCap = min(self.firstChunkCap, providerCap)
        }
    }

    /// A piece of text destined for a chunk, plus whether a space separates it from
    /// whatever precedes it, wherever it lands, plus where it came from in the source.
    ///
    /// `spaced` is false for: the second and later fragments produced by hard-splitting
    /// a single word that alone exceeded the character cap (e.g. a long URL), and for a
    /// clause piece that follows a clause-boundary delimiter (`,` `;` `:`) with no
    /// actual whitespace after it in the source (again, a URL's "https:" is the
    /// motivating case). In both cases there was never a real space at that seam, so
    /// treating it as spaced would insert a character that was never in the input.
    ///
    /// `sourceStart`/`sourceEnd` are `Character` offsets into the `trimmed` string built
    /// at the top of `segment(_:)` — carried forward from wherever this unit's text was
    /// actually extracted (a sentence range, a clause range, a word range, or a hard-split
    /// fragment), never recomputed by searching for the text afterward. Searching breaks
    /// on repeated text and can't recover the dropped-space case; threading the offset
    /// through each split step is the only way that's actually correct.
    ///
    /// `startsSentence` marks the very first unit produced for a given sentence — the one
    /// whose `sourceStart` is where a new sentence begins. Every later unit that sentence
    /// was split into (clause pieces, word-boundary pieces, hard-split fragments) is a
    /// continuation, not a new sentence start.
    private struct Unit {
        let text: String
        let spaced: Bool
        let sourceStart: Int
        let sourceEnd: Int
        var startsSentence: Bool = false
        /// A paragraph break followed this unit in the source. Forces a chunk boundary,
        /// so the pause `AudioSeam` gives a paragraph lands in the right place.
        var endsParagraph: Bool = false
    }

    /// The options this segmenter was built with. Readable because callers that hand a
    /// `Segmenter` to something else — `SpeechSession` does — otherwise have no way to
    /// report which cap is actually in force.
    public let options: Options
    private let estimator: DurationEstimator

    public init(options: Options = Options(),
                estimator: DurationEstimator = DurationEstimator()) {
        self.options = options
        self.estimator = estimator
    }

    public func segment(_ text: String) -> [Chunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // `trimmed` may start later than `text` (leading whitespace/newlines stripped).
        // Every offset computed below is relative to `trimmed`; this is added back at
        // the end so chunks index into `text` — the prepared string callers actually
        // handed us — rather than into our own internal, further-trimmed copy of it.
        let leadingTrim: Int
        if let contentRange = trimmedIndices(of: text.startIndex..<text.endIndex, in: text,
                                             isWhitespace: isWhitespaceOrNewline) {
            leadingTrim = text.distance(from: text.startIndex, to: contentRange.lowerBound)
        } else {
            leadingTrim = 0
        }

        // Units are sentences; anything over the cap is pre-split into clause or word
        // pieces so the packer only ever sees things that fit.
        var units: [Unit] = []
        let found = sentences(in: trimmed)
        for (index, sentence) in found.enumerated() {
            let nextStart = index + 1 < found.count ? found[index + 1].start : trimmed.count
            var sentenceUnits: [Unit]
            if sentence.text.count <= options.characterCap {
                sentenceUnits = [Unit(text: sentence.text, spaced: true,
                                      sourceStart: sentence.start,
                                      sourceEnd: sentence.start + sentence.text.count)]
            } else {
                sentenceUnits = splitOversized(sentence.text, base: sentence.start)
            }
            // Only the first unit this sentence produced is where the sentence actually
            // starts; everything after it is a continuation of the same sentence.
            if !sentenceUnits.isEmpty {
                sentenceUnits[0].startsSentence = true
                // `TextPreparer` leaves exactly one kind of newline in the prepared text:
                // a paragraph break. NLTokenizer treats it as whitespace between
                // sentences and drops it, so it is found by looking at the gap rather
                // than in the sentence text.
                let gapStart = sentence.start + sentence.text.count
                if Self.containsNewline(in: trimmed, from: gapStart, to: nextStart) {
                    sentenceUnits[sentenceUnits.count - 1].endsParagraph = true
                }
            }
            units.append(contentsOf: sentenceUnits)
        }

        return pack(units, offsetAdjustment: leadingTrim)
    }

    /// Whether `text` holds a newline in `[from, to)`, in Character offsets.
    private static func containsNewline(in text: String, from: Int, to: Int) -> Bool {
        guard from < to, to <= text.count, from >= 0 else { return false }
        let start = text.index(text.startIndex, offsetBy: from)
        let end = text.index(text.startIndex, offsetBy: to)
        return text[start..<end].contains("\n")
    }

    // MARK: - Sentence detection

    private func sentences(in text: String) -> [(text: String, start: Int)] {
        // NLTokenizer knows that "Dr." is not a sentence end.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [(String, Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard let trimmedRange = trimmedIndices(of: range, in: text,
                                                     isWhitespace: isWhitespaceOrNewline) else {
                return true
            }
            let s = String(text[trimmedRange])
            let start = text.distance(from: text.startIndex, to: trimmedRange.lowerBound)
            result.append((s, start))
            return true
        }
        return result.isEmpty ? [(text, 0)] : result
    }

    // MARK: - Oversized sentence handling

    /// Clause boundaries first, then words. Never mid-word — unless a single word alone
    /// exceeds the cap, in which case the cap wins (see `splitAtWordBoundaries`).
    ///
    /// `base` is this sentence's absolute start offset (into `trimmed`), so every piece
    /// produced below can report its own absolute offset rather than one relative to
    /// whatever substring it was carved from.
    private func splitOversized(_ sentence: String, base: Int) -> [Unit] {
        var pieces: [Unit] = []
        for clause in splitAtClauseBoundaries(sentence, base: base) {
            if clause.text.count <= options.characterCap {
                pieces.append(clause)
            } else {
                pieces.append(contentsOf: splitAtWordBoundaries(clause.text, base: clause.sourceStart,
                                                                 leadingSpaced: clause.spaced))
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
    private func splitAtClauseBoundaries(_ sentence: String, base: Int) -> [Unit] {
        var pieces: [Unit] = []
        var current = ""
        var currentStart = 0
        var spaced = true
        var pos = 0
        var index = sentence.startIndex
        while index < sentence.endIndex {
            let character = sentence[index]
            current.append(character)
            if character == "," || character == ";" || character == ":" {
                appendClausePiece(&pieces, raw: current, rawStart: currentStart, base: base, spaced: spaced)
                current = ""
                let next = sentence.index(after: index)
                currentStart = pos + 1
                spaced = next < sentence.endIndex && sentence[next].isWhitespace
            }
            pos += 1
            index = sentence.index(after: index)
        }
        appendClausePiece(&pieces, raw: current, rawStart: currentStart, base: base, spaced: spaced)
        if pieces.isEmpty {
            pieces = [Unit(text: sentence, spaced: true, sourceStart: base, sourceEnd: base + sentence.count)]
        }
        return pieces
    }

    /// Trims `raw` exactly as the original clause splitter did (`.whitespaces`, not
    /// `.whitespacesAndNewlines`) and, if anything survives, appends a `Unit` whose
    /// offset accounts for however many leading whitespace characters were stripped.
    private func appendClausePiece(_ pieces: inout [Unit], raw: String, rawStart: Int, base: Int, spaced: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let leading = raw.prefix(while: isClauseWhitespace).count
        let start = base + rawStart + leading
        pieces.append(Unit(text: trimmed, spaced: spaced, sourceStart: start, sourceEnd: start + trimmed.count))
    }

    /// `leadingSpaced` carries the spacing of the clause this word run came from: the
    /// very first piece this call produces inherits it, since that seam is the clause
    /// boundary handled by the caller. Every later piece within this call is a genuine
    /// interior word-boundary split (on a literal `" "`) or a hard-split continuation, so
    /// its spacing is decided locally.
    ///
    /// `base` is `clause`'s own absolute start offset, so a word's position within
    /// `clause` (from `wordsWithPositions`) converts to an absolute offset by simple
    /// addition.
    private func splitAtWordBoundaries(_ clause: String, base: Int, leadingSpaced: Bool) -> [Unit] {
        var pieces: [Unit] = []
        var current: [(text: String, start: Int)] = []
        var length = 0

        func flushLine() {
            guard !current.isEmpty else { return }
            let spaced = pieces.isEmpty ? leadingSpaced : true
            let text = current.map(\.text).joined(separator: " ")
            let start = current[0].start
            let last = current[current.count - 1]
            let end = last.start + last.text.count
            pieces.append(Unit(text: text, spaced: spaced, sourceStart: start, sourceEnd: end))
            current = []
            length = 0
        }

        for (word, localStart) in wordsWithPositions(clause) {
            let absStart = base + localStart
            if word.count > options.characterCap {
                // A single word longer than the cap can't be emitted whole: the cap is
                // the hard constraint (silent audio loss above it), so it wins over
                // "never split mid-word" for this one pathological case. Split on
                // Character boundaries so multi-byte grapheme clusters are never torn.
                flushLine()
                var fragmentStart = absStart
                for (index, fragment) in hardSplit(word).enumerated() {
                    let spaced = index == 0 ? (pieces.isEmpty ? leadingSpaced : true) : false
                    let fragmentEnd = fragmentStart + fragment.count
                    pieces.append(Unit(text: fragment, spaced: spaced,
                                       sourceStart: fragmentStart, sourceEnd: fragmentEnd))
                    fragmentStart = fragmentEnd
                }
                continue
            }
            let added = current.isEmpty ? word.count : word.count + 1
            if length + added > options.characterCap, !current.isEmpty {
                // Break where a speaker would breathe, not wherever the cap happened to
                // fall. Packing greedily put a boundary after "the well" in "potential to
                // become the well balanced contributor", which is heard as a pause in the
                // middle of a noun phrase — and worse, as the noun "well".
                //
                // So back up to the last word that starts a phrase and break in front of
                // it instead. Only if that does not throw away too much of the chunk:
                // below `minimumFill` the saving in awkwardness is not worth the extra
                // seam, and a long run with no function word in it has no better answer
                // than the cap anyway.
                let breakIndex = Self.phraseBreak(in: current,
                                                  notBefore: Int(Double(options.characterCap)
                                                                 * Self.minimumFill))
                if let breakIndex {
                    let carried = Array(current[breakIndex...])
                    current = Array(current[..<breakIndex])
                    flushLine()
                    current = carried
                    length = carried.map(\.text.count).reduce(0, +) + carried.count - 1
                } else {
                    flushLine()
                }
                current.append((word, absStart))
                length += current.count == 1 ? word.count : word.count + 1
            } else {
                current.append((word, absStart))
                length += added
            }
        }
        flushLine()
        return pieces
    }


    /// Where in a run of words a break would sound deliberate.
    ///
    /// Returns the index of the last word that opens a phrase — a preposition, a
    /// conjunction, a relative pronoun — so the caller can break immediately before it.
    /// Nil when there is no such word late enough in the run to be worth taking, in which
    /// case the cap decides and the break falls wherever it falls.
    ///
    /// `notBefore` is a character count: a break earlier than this leaves too little in
    /// the outgoing chunk to be worth the extra seam.
    static func phraseBreak(in words: [(text: String, start: Int)],
                            notBefore: Int) -> Int? {
        var consumed = 0
        var best: Int?
        for (index, word) in words.enumerated() {
            if index > 0, consumed >= notBefore,
               phraseOpeners.contains(word.text.lowercased()
                   .trimmingCharacters(in: .punctuationCharacters)) {
                best = index
            }
            consumed += word.text.count + (index > 0 ? 1 : 0)
        }
        return best
    }

    /// How much of the cap a chunk must already hold before a nicer break point is worth
    /// taking. Below this the saving in awkwardness costs an extra seam and a shorter
    /// chunk, which is a worse trade.
    static let minimumFill = 0.55

    /// Words that begin a phrase in English, so a pause in front of one sounds like a
    /// breath rather than an interruption. Deliberately short and closed-class: this is
    /// not a parser, and a longer list would start breaking in front of words that carry
    /// the sentence rather than join it.
    static let phraseOpeners: Set<String> = [
        "and", "or", "but", "so", "yet", "nor",
        "to", "of", "in", "on", "at", "by", "for", "from", "with", "without",
        "into", "onto", "about", "after", "before", "during", "through", "under", "over",
        "within", "upon", "between", "among", "against", "across", "toward", "towards",
        "throughout", "beyond", "beneath", "behind",
        "as", "than", "that", "which", "who", "whom", "whose", "when", "where", "while",
        "because", "although", "though", "if", "unless", "until", "since",
    ]

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

    // MARK: - Offset helpers

    /// True for a `Character` made of exactly one Unicode scalar that is itself a member
    /// of `set`. Whitespace is always single-scalar in the text this type handles, so
    /// this reproduces `String.trimmingCharacters(in:)`'s behavior at the granularity
    /// (`Character`) the rest of this type works in, letting offsets be computed by
    /// counting characters rather than re-deriving them from a `String.Index` walk.
    private func matches(_ character: Character, _ set: CharacterSet) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return set.contains(scalar)
    }

    private func isClauseWhitespace(_ character: Character) -> Bool {
        matches(character, .whitespaces)
    }

    private func isWhitespaceOrNewline(_ character: Character) -> Bool {
        matches(character, .whitespacesAndNewlines)
    }

    /// The sub-range of `range` (within `s`) left after trimming characters matching
    /// `isWhitespace` from both ends — index-based, so the caller can recover exactly
    /// where the trimmed text sits in `s`, which `String.trimmingCharacters(in:)` alone
    /// throws away. Returns nil if nothing survives.
    private func trimmedIndices(of range: Range<String.Index>, in s: String,
                                isWhitespace: (Character) -> Bool) -> Range<String.Index>? {
        var lower = range.lowerBound
        while lower < range.upperBound, isWhitespace(s[lower]) {
            lower = s.index(after: lower)
        }
        var upper = range.upperBound
        while upper > lower, isWhitespace(s[s.index(before: upper)]) {
            upper = s.index(before: upper)
        }
        return lower < upper ? lower..<upper : nil
    }

    /// Splits on a literal `" "` character, exactly like `s.split(separator: " ")`
    /// (consecutive spaces collapse, leading/trailing spaces are dropped) — but keeps
    /// each word's `Character` offset within `s`, which `split(separator:)` discards.
    private func wordsWithPositions(_ s: String) -> [(text: String, start: Int)] {
        var result: [(String, Int)] = []
        var word: [Character] = []
        var wordStart = 0
        var pos = 0
        var index = s.startIndex
        while index < s.endIndex {
            let character = s[index]
            if character == " " {
                if !word.isEmpty {
                    result.append((String(word), wordStart))
                    word = []
                }
            } else {
                if word.isEmpty { wordStart = pos }
                word.append(character)
            }
            pos += 1
            index = s.index(after: index)
        }
        if !word.isEmpty { result.append((String(word), wordStart)) }
        return result
    }

    // MARK: - Packing

    /// `offsetAdjustment` converts a unit's `trimmed`-relative offset into one relative
    /// to the original `text` argument of `segment(_:)` — the prepared string the caller
    /// actually handed us.
    private func pack(_ units: [Unit], offsetAdjustment: Int) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentText = ""
        var currentStart: Int?
        var currentEnd = 0
        var currentSentenceOffsets: [Int] = []
        var currentEndsParagraph = false

        func capForNextChunk() -> Int {
            chunks.isEmpty ? min(options.firstChunkCap, options.characterCap)
                           : options.characterCap
        }

        func emit() {
            guard !currentText.isEmpty else { return }
            chunks.append(Chunk(id: chunks.count,
                                text: currentText,
                                estimatedDuration: estimator.estimate(characterCount: currentText.count),
                                sourceStart: currentStart ?? offsetAdjustment,
                                sourceEnd: currentEnd,
                                sentenceOffsets: currentSentenceOffsets,
                                endsParagraph: currentEndsParagraph))
            currentText = ""
            currentStart = nil
            currentSentenceOffsets = []
            currentEndsParagraph = false
        }

        /// Starts a brand-new chunk-in-progress with `unit` as its only content so far.
        ///
        /// `leadingSourceSpace` is true only when `textOverride` prepends a synthetic
        /// `" "` that represents a real separator character actually present in the
        /// source immediately before `unit` (the "attach the seam space to the front of
        /// the new chunk" case below) — in which case `sourceStart` must start one
        /// character earlier than `unit.sourceStart` so this chunk's `[sourceStart,
        /// sourceEnd)` still covers exactly what `text` holds. It must NOT be set for the
        /// dropped-space case: there, nothing was written into `currentText` for that
        /// seam, so `sourceStart` staying at `unit.sourceStart` is already correct.
        func startNewChunk(with unit: Unit, textOverride: String? = nil, sentenceOffset: Int = 0,
                           leadingSourceSpace: Bool = false) {
            currentText = textOverride ?? unit.text
            currentStart = unit.sourceStart + offsetAdjustment - (leadingSourceSpace ? 1 : 0)
            currentEnd = unit.sourceEnd + offsetAdjustment
            if unit.startsSentence { currentSentenceOffsets.append(sentenceOffset) }
        }

        for unit in units {
            let wantsSpace = !currentText.isEmpty && unit.spaced
            let cap = capForNextChunk()
            let need = (wantsSpace ? 1 : 0) + unit.text.count
            let unitAbsEnd = unit.sourceEnd + offsetAdjustment

            if currentText.isEmpty || currentText.count + need <= cap {
                // Fits in the chunk being built — or there's nothing to flush and this
                // unit must be placed regardless (the accepted firstChunkCap overflow;
                // characterCap can never be exceeded here since every unit is already
                // sized to fit within it).
                if wantsSpace { currentText += " " }
                if unit.startsSentence { currentSentenceOffsets.append(currentText.count) }
                currentText += unit.text
                if currentStart == nil { currentStart = unit.sourceStart + offsetAdjustment }
                currentEnd = unitAbsEnd
                // A paragraph ends the chunk regardless of how much room is left. The
                // pause belongs at the boundary, and `AudioSeam` can only put it between
                // chunks — text packed on after this one would bury it mid-chunk, where
                // Kokoro decides the timing and treats it as an ordinary sentence.
                if unit.endsParagraph {
                    currentEndsParagraph = true
                    emit()
                }
                continue
            }

            // Doesn't fit alongside what's already here. Flush first. If a real space
            // belongs between the outgoing text and this unit, don't let it vanish at
            // the seam: attach it wherever there is room, preferring the front of the
            // new chunk (so a clause/sentence boundary like "...it," doesn't end up with
            // a trailing space baked into the outgoing chunk). characterCap outranks
            // this: if neither side has room the space is dropped (cap wins) — this can
            // only happen when both the outgoing chunk and the incoming unit are each
            // already sized exactly to the cap, which is rare. The dropped space is
            // still correctly unrepresented in the next chunk's sourceStart: that offset
            // comes from the unit itself, not from counting characters in `currentText`,
            // so it points at the unit's real position in the source whether or not a
            // space was written into the text right before it.
            let outgoingHadRoomForTrailingSpace = currentText.count + 1 <= cap
            emit()

            guard wantsSpace else {
                startNewChunk(with: unit)
                continue
            }
            if 1 + unit.text.count <= options.characterCap {
                startNewChunk(with: unit, textOverride: " " + unit.text, sentenceOffset: 1,
                             leadingSourceSpace: true)
            } else if outgoingHadRoomForTrailingSpace, let last = chunks.indices.last {
                let text = chunks[last].text + " "
                chunks[last] = Chunk(id: chunks[last].id,
                                     text: text,
                                     estimatedDuration: estimator.estimate(characterCount: text.count),
                                     sourceStart: chunks[last].sourceStart,
                                     // The source really does have a space here (wantsSpace
                                     // is true), so extending sourceEnd by one keeps this
                                     // chunk's [sourceStart, sourceEnd) matching its text.
                                     sourceEnd: chunks[last].sourceEnd + 1,
                                     sentenceOffsets: chunks[last].sentenceOffsets,
                                     endsParagraph: chunks[last].endsParagraph)
                startNewChunk(with: unit)
            } else {
                startNewChunk(with: unit)
            }

            // Same rule as the fits-branch above, and it has to be repeated here because
            // this path starts a fresh chunk rather than appending to one. Without it a
            // paragraph is only marked when its last sentence happened to fit alongside
            // what came before — which, in any document long enough to fill a chunk, is
            // almost never.
            if unit.endsParagraph {
                currentEndsParagraph = true
                emit()
            }
        }
        emit()
        return chunks
    }
}
