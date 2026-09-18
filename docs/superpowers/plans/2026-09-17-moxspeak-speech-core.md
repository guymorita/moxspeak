# MoxSpeak Speech Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless speech pipeline — raw text in, audio out of the speakers — driven by a CLI, with no AppKit, no Accessibility permissions, and no UI.

**Architecture:** A Swift Package Manager library (`MoxSpeakCore`) holding every piece of logic, plus a thin executable target (`moxspeak`) that wires them together. Text flows through `TextPreparer` (de-format) → `Segmenter` (cap at 150 chars) → `SpeechSession` (orchestration, prefetch, validation) → `SpeechProvider` (HTTP) → `PlaybackEngine` (AVAudioEngine). Everything except `PlaybackEngine` is tested against a `FakeProvider` with no network and no audio hardware.

**Tech Stack:** Swift 6.0.2, swift-tools-version 6.0, macOS 14 target, Swift Testing (`import Testing`), AVFoundation, URLSession. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-17-moxspeak-tts-design.md`

## Global Constraints

- **Swift tools version 6.0**, platform `.macOS(.v14)`. Verified working on Swift 6.0.2 / Xcode 16.1 / arm64.
- **Zero third-party dependencies.** Foundation, AVFoundation, NaturalLanguage, Testing only.
- **Test command is always `swift test`** from the package root. No Xcode project in this plan.
- **Chunk character cap defaults to 150.** The backend is unreliable above ~180 characters (spec, Known Issues). Never raise this default without re-running the measurement sweep.
- **Speech density constant is 15.4 characters per second.** Measured range 14.3–15.6.
- **Kokoro audio format is raw headerless PCM: 24000 Hz, 1 channel, 16-bit signed little-endian.** 48000 bytes per second of audio.
- **Never send user text to an unidentified endpoint.** Provider construction takes an explicit base URL; there is no port scanning or auto-discovery in this plan.
- **Deviation from spec, deliberate:** the spec specifies `synthesize -> AsyncStream<Data>`. Measurement showed time-to-first-audio equals time-to-completion for chunks at this size (0.57s vs 0.57s at 180 chars), so per-chunk streaming buys nothing. `synthesize` returns `Data`; cancellation uses Swift structured concurrency.

---

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Package definition, two targets plus tests |
| `Sources/MoxSpeakCore/Models.swift` | `AudioFormat`, `Chunk`, `ChunkState`, `Voice`, `SpeechError` |
| `Sources/MoxSpeakCore/DurationEstimator.swift` | Characters ↔ seconds ↔ PCM bytes |
| `Sources/MoxSpeakCore/TextPreparer.swift` | Markdown/PDF/emoji de-formatting |
| `Sources/MoxSpeakCore/Segmenter.swift` | Sentence splitting and capped chunk packing |
| `Sources/MoxSpeakCore/SpeechProvider.swift` | Provider protocol and `FakeProvider` |
| `Sources/MoxSpeakCore/OpenAICompatibleProvider.swift` | Real HTTP provider |
| `Sources/MoxSpeakCore/SpeechSession.swift` | Orchestration, generations, prefetch, validation |
| `Sources/MoxSpeakCore/PlaybackEngine.swift` | AVAudioEngine playback |
| `Sources/moxspeak/main.swift` | CLI entry point |
| `Tests/MoxSpeakCoreTests/*.swift` | One test file per source file |

---

### Task 1: Package scaffold and test harness

**Files:**
- Create: `Package.swift`
- Create: `Sources/MoxSpeakCore/Models.swift`
- Create: `Tests/MoxSpeakCoreTests/ModelsTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `AudioFormat`, `Voice`, `SpeechError`, `Chunk`, `ChunkState` — used by every later task.

- [ ] **Step 1: Create the package layout**

```bash
cd /Users/guymorita/Dev/moxspeak
mkdir -p Sources/MoxSpeakCore Sources/moxspeak Tests/MoxSpeakCoreTests
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoxSpeak",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoxSpeakCore", targets: ["MoxSpeakCore"]),
        .executable(name: "moxspeak", targets: ["moxspeak"]),
    ],
    targets: [
        .target(name: "MoxSpeakCore"),
        .executableTarget(name: "moxspeak", dependencies: ["MoxSpeakCore"]),
        .testTarget(name: "MoxSpeakCoreTests", dependencies: ["MoxSpeakCore"]),
    ]
)
```

- [ ] **Step 3: Write the failing test**

Create `Tests/MoxSpeakCoreTests/ModelsTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

@Test func kokoroFormatHasExpectedByteRate() {
    let f = AudioFormat.kokoroPCM
    #expect(f.sampleRate == 24000)
    #expect(f.channels == 1)
    #expect(f.bitDepth == 16)
    #expect(f.bytesPerSecond == 48000)
}

@Test func chunkStateRenderedCarriesDuration() {
    let state = ChunkState.rendered(data: Data([0, 0]), duration: 1.5)
    guard case .rendered(_, let duration) = state else {
        Issue.record("expected rendered state")
        return
    }
    #expect(duration == 1.5)
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test 2>&1 | tail -20`
Expected: FAIL — compile error, `cannot find 'AudioFormat' in scope`.

- [ ] **Step 5: Write `Sources/MoxSpeakCore/Models.swift`**

```swift
import Foundation

public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let bitDepth: Int
    /// True when bytes arrive headerless (raw samples), false when wrapped in a container.
    public let isRawPCM: Bool

    public init(sampleRate: Double, channels: Int, bitDepth: Int, isRawPCM: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isRawPCM = isRawPCM
    }

    public var bytesPerSecond: Int {
        Int(sampleRate) * channels * (bitDepth / 8)
    }

    /// Kokoro-FastAPI `response_format: "pcm"` — raw headerless signed 16-bit LE mono.
    public static let kokoroPCM = AudioFormat(
        sampleRate: 24000, channels: 1, bitDepth: 16, isRawPCM: true
    )
}

public struct Voice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Chunk: Equatable, Sendable, Identifiable {
    public let id: Int
    public let text: String
    public let estimatedDuration: TimeInterval

    public init(id: Int, text: String, estimatedDuration: TimeInterval) {
        self.id = id
        self.text = text
        self.estimatedDuration = estimatedDuration
    }

    public var characterCount: Int { text.count }
}

public enum ChunkState: Sendable {
    case pending
    case synthesizing
    case rendered(data: Data, duration: TimeInterval)
    case failed(reason: String)
}

public enum SpeechError: Error, Equatable, Sendable {
    case httpStatus(code: Int, body: String)
    case emptyAudio
    case shortAudio(expected: TimeInterval, got: TimeInterval)
    case formatMismatch(expected: AudioFormat, got: AudioFormat)
    case transport(String)
    case badResponse(String)
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test 2>&1 | tail -20`
Expected: PASS — 2 tests.

- [ ] **Step 7: Commit**

```bash
cd /Users/guymorita/Dev/moxspeak
git add Package.swift Sources Tests
git commit -m "feat(core): package scaffold and core model types"
```

---

### Task 2: DurationEstimator

**Files:**
- Create: `Sources/MoxSpeakCore/DurationEstimator.swift`
- Create: `Tests/MoxSpeakCoreTests/DurationEstimatorTests.swift`

**Interfaces:**
- Consumes: `AudioFormat` (Task 1)
- Produces:
  - `DurationEstimator.init(charsPerSecond: Double = 15.4)`
  - `func estimate(characterCount: Int) -> TimeInterval`
  - `func duration(ofBytes: Int, format: AudioFormat) -> TimeInterval`
  - `static let defaultCharsPerSecond: Double`

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/DurationEstimatorTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

@Test func estimatesFromCharacterCount() {
    let e = DurationEstimator()
    // 154 chars at 15.4 chars/sec == 10 seconds
    #expect(abs(e.estimate(characterCount: 154) - 10.0) < 0.001)
}

@Test func measuresDurationFromPCMBytes() {
    let e = DurationEstimator()
    // 48000 bytes == 1 second of 24kHz 16-bit mono
    #expect(e.duration(ofBytes: 48000, format: .kokoroPCM) == 1.0)
    #expect(e.duration(ofBytes: 24000, format: .kokoroPCM) == 0.5)
}

@Test func emptyInputHasZeroDuration() {
    let e = DurationEstimator()
    #expect(e.estimate(characterCount: 0) == 0)
    #expect(e.duration(ofBytes: 0, format: .kokoroPCM) == 0)
}

@Test func estimateMatchesMeasuredBaseline() {
    // Spec baseline: 180 chars produced 11.6s of audio.
    let e = DurationEstimator()
    let estimated = e.estimate(characterCount: 180)
    #expect(abs(estimated - 11.6) < 0.5)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DurationEstimator 2>&1 | tail -20`
Expected: FAIL — `cannot find 'DurationEstimator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MoxSpeakCore/DurationEstimator.swift`:

```swift
import Foundation

/// Converts between character counts, wall-clock seconds of speech, and audio byte counts.
///
/// The characters-per-second constant is measured, not theoretical: 15.4 chars/sec,
/// observed range 14.3-15.6 against Kokoro-FastAPI on an M2 Max. See the spec's
/// "Measured baseline" section. It is configurable because it is an engine property.
public struct DurationEstimator: Sendable {
    public static let defaultCharsPerSecond: Double = 15.4

    public let charsPerSecond: Double

    public init(charsPerSecond: Double = DurationEstimator.defaultCharsPerSecond) {
        precondition(charsPerSecond > 0, "charsPerSecond must be positive")
        self.charsPerSecond = charsPerSecond
    }

    /// Predicted speech duration for text of this length, before synthesis.
    public func estimate(characterCount: Int) -> TimeInterval {
        guard characterCount > 0 else { return 0 }
        return Double(characterCount) / charsPerSecond
    }

    /// Actual duration of received audio. Exact for raw PCM.
    public func duration(ofBytes byteCount: Int, format: AudioFormat) -> TimeInterval {
        guard byteCount > 0, format.bytesPerSecond > 0 else { return 0 }
        return Double(byteCount) / Double(format.bytesPerSecond)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter DurationEstimator 2>&1 | tail -20`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MoxSpeakCore/DurationEstimator.swift Tests/MoxSpeakCoreTests/DurationEstimatorTests.swift
git commit -m "feat(core): duration estimator with measured chars-per-second constant"
```

---

### Task 3: TextPreparer

Covers only what Kokoro's normalizer does not: document formatting. Do not add number, date, currency, URL, or abbreviation handling — the backend already does those, and duplicating them causes double-normalization bugs.

**Files:**
- Create: `Sources/MoxSpeakCore/TextPreparer.swift`
- Create: `Tests/MoxSpeakCoreTests/TextPreparerTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `TextPreparer.Options` with `stripMarkdown`, `codeBlocks`, `stripCitationBrackets`, `rejoinHardWraps`, `stripEmoji`
  - `TextPreparer.CodeBlockHandling` enum: `.skip`, `.announce`, `.keep`
  - `TextPreparer.init(options: Options = Options())`
  - `func prepare(_ raw: String) -> String`

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/TextPreparerTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

@Test func stripsMarkdownEmphasisAndHeadings() {
    let p = TextPreparer()
    #expect(p.prepare("## The **bold** truth") == "The bold truth")
    #expect(p.prepare("It was *very* cold.") == "It was very cold.")
    #expect(p.prepare("Use `swift test` now.") == "Use swift test now.")
}

@Test func reducesMarkdownLinksToLabel() {
    let p = TextPreparer()
    #expect(p.prepare("See [the docs](https://example.com/a/b) today.")
            == "See the docs today.")
}

@Test func stripsListBullets() {
    let p = TextPreparer()
    #expect(p.prepare("- first\n- second") == "first second")
}

@Test func stripsCitationBrackets() {
    let p = TextPreparer()
    #expect(p.prepare("This is established [12] and known [3].")
            == "This is established and known.")
}

@Test func rejoinsPdfHyphenationAndHardWraps() {
    let p = TextPreparer()
    let pdf = "The quick brown fox jum-\nped over the lazy\ndog."
    #expect(p.prepare(pdf) == "The quick brown fox jumped over the lazy dog.")
}

@Test func preservesParagraphBreaksAsSentenceBoundaries() {
    let p = TextPreparer()
    let input = "First para.\n\nSecond para."
    #expect(p.prepare(input) == "First para. Second para.")
}

@Test func announcesFencedCodeBlocksByDefault() {
    let p = TextPreparer()
    let input = "Before.\n```swift\nlet x = 1\n```\nAfter."
    #expect(p.prepare(input) == "Before. Code block. After.")
}

@Test func skipsCodeBlocksWhenConfigured() {
    var opts = TextPreparer.Options()
    opts.codeBlocks = .skip
    let p = TextPreparer(options: opts)
    let input = "Before.\n```swift\nlet x = 1\n```\nAfter."
    #expect(p.prepare(input) == "Before. After.")
}

@Test func stripsEmoji() {
    let p = TextPreparer()
    #expect(p.prepare("Shipped it 🚀🎉 today.") == "Shipped it today.")
}

@Test func normalizesSmartQuotesAndEllipses() {
    let p = TextPreparer()
    #expect(p.prepare("\u{201C}Wait\u{2026}\u{201D} he said.") == "\"Wait...\" he said.")
}

@Test func leavesPlainProseUntouched() {
    let p = TextPreparer()
    let prose = "It was a bright cold day in April, and the clocks were striking thirteen."
    #expect(p.prepare(prose) == prose)
}

@Test func doesNotTouchNumbersOrUrlsOrAbbreviations() {
    // The backend normalizer owns these. Double-handling them is a bug.
    let p = TextPreparer()
    let input = "Dr. Smith paid $1,200 on 3/4/2026 via https://pay.example.com"
    #expect(p.prepare(input) == input)
}

@Test func handlesEmptyAndWhitespaceOnlyInput() {
    let p = TextPreparer()
    #expect(p.prepare("") == "")
    #expect(p.prepare("   \n\n  ") == "")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TextPreparer 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TextPreparer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MoxSpeakCore/TextPreparer.swift`:

```swift
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

        if options.rejoinHardWraps {
            text = rejoinHardWraps(text)
        }
        if options.stripMarkdown {
            text = stripMarkdown(text)
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

    private func rejoinHardWraps(_ text: String) -> String {
        var out = text
        // "jum-\nped" -> "jumped". Hyphen plus newline is always a PDF wrap artifact.
        out = out.replacing(/(\w)-\n[ \t]*(\w)/) { m in "\(m.1)\(m.2)" }
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TextPreparer 2>&1 | tail -30`
Expected: PASS — 13 tests. If the emoji or whitespace tests fail on spacing, adjust `collapseWhitespace` ordering rather than loosening the assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources/MoxSpeakCore/TextPreparer.swift Tests/MoxSpeakCoreTests/TextPreparerTests.swift
git commit -m "feat(core): text preparer for markdown, PDF wraps, citations and emoji"
```

---

### Task 4: Segmenter

**Files:**
- Create: `Sources/MoxSpeakCore/Segmenter.swift`
- Create: `Tests/MoxSpeakCoreTests/SegmenterTests.swift`

**Interfaces:**
- Consumes: `Chunk` (Task 1), `DurationEstimator` (Task 2)
- Produces:
  - `Segmenter.Options` with `characterCap: Int = 150`, `firstChunkCap: Int = 100`
  - `Segmenter.init(options: Options = Options(), estimator: DurationEstimator = DurationEstimator())`
  - `func segment(_ text: String) -> [Chunk]`

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/SegmenterTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

private func makeSegmenter(cap: Int = 150, firstCap: Int = 100) -> Segmenter {
    var o = Segmenter.Options()
    o.characterCap = cap
    o.firstChunkCap = firstCap
    return Segmenter(options: o)
}

@Test func noChunkExceedsTheCap() {
    let s = makeSegmenter()
    let text = String(repeating: "This is a sentence of moderate length. ", count: 40)
    let chunks = s.segment(text)
    #expect(!chunks.isEmpty)
    for c in chunks {
        #expect(c.characterCount <= 150, "chunk \(c.id) was \(c.characterCount) chars")
    }
}

@Test func firstChunkRespectsTheSmallerFirstCap() {
    let s = makeSegmenter()
    let text = String(repeating: "Another ordinary sentence here. ", count: 30)
    let chunks = s.segment(text)
    #expect(chunks[0].characterCount <= 100)
}

@Test func splitsAGiantSingleSentenceWithoutBreakingWords() {
    let s = makeSegmenter()
    // One sentence, no internal punctuation, far over the cap.
    let giant = Array(repeating: "wordy", count: 400).joined(separator: " ") + "."
    let chunks = s.segment(giant)
    #expect(chunks.count > 1)
    for c in chunks {
        #expect(c.characterCount <= 150)
        // No chunk may start or end mid-word.
        #expect(!c.text.hasPrefix("ordy"))
        #expect(c.text.split(separator: " ").allSatisfy { $0 == "wordy" || $0 == "wordy." })
    }
}

@Test func prefersClauseBoundariesInsideLongSentences() {
    let s = makeSegmenter(cap: 60, firstCap: 60)
    let text = "This clause is here, and this clause follows it, and a third one closes."
    let chunks = s.segment(text)
    #expect(chunks.count >= 2)
    // A clause split should leave the comma attached to the earlier chunk.
    #expect(chunks[0].text.hasSuffix(",") || chunks[0].text.hasSuffix("it,")
            || chunks[0].text.hasSuffix("here,"))
}

@Test func doesNotSplitOnAbbreviationPeriods() {
    let s = makeSegmenter()
    let chunks = s.segment("Dr. Smith went home. Mr. Jones stayed.")
    #expect(chunks.count == 1)
    #expect(chunks[0].text.contains("Dr. Smith"))
}

@Test func packsShortSentencesTogether() {
    let s = makeSegmenter()
    let chunks = s.segment("One. Two. Three. Four.")
    #expect(chunks.count == 1)
}

@Test func assignsSequentialIdsAndEstimates() {
    let s = makeSegmenter()
    let text = String(repeating: "A sentence that is reasonably long goes here. ", count: 20)
    let chunks = s.segment(text)
    for (i, c) in chunks.enumerated() {
        #expect(c.id == i)
        #expect(c.estimatedDuration > 0)
    }
}

@Test func emptyAndWhitespaceInputProduceNoChunks() {
    let s = makeSegmenter()
    #expect(s.segment("").isEmpty)
    #expect(s.segment("    ").isEmpty)
}

@Test func singleWordProducesOneChunk() {
    let s = makeSegmenter()
    let chunks = s.segment("Hello")
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "Hello")
}

@Test func coversEveryWordOfTheInput() {
    let s = makeSegmenter()
    let text = String(repeating: "Coverage matters a great deal here. ", count: 25)
    let chunks = s.segment(text)
    let rejoined = chunks.map(\.text).joined(separator: " ")
    let originalWords = text.split(separator: " ").map(String.init)
    let rejoinedWords = rejoined.split(separator: " ").map(String.init)
    #expect(originalWords == rejoinedWords)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter Segmenter 2>&1 | tail -20`
Expected: FAIL — `cannot find 'Segmenter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MoxSpeakCore/Segmenter.swift`:

```swift
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter Segmenter 2>&1 | tail -30`
Expected: PASS — 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MoxSpeakCore/Segmenter.swift Tests/MoxSpeakCoreTests/SegmenterTests.swift
git commit -m "feat(core): segmenter with hard character cap and clause/word splitting"
```

---

### Task 5: SpeechProvider protocol and FakeProvider

**Files:**
- Create: `Sources/MoxSpeakCore/SpeechProvider.swift`
- Create: `Tests/MoxSpeakCoreTests/FakeProviderTests.swift`

**Interfaces:**
- Consumes: `AudioFormat`, `Voice`, `SpeechError` (Task 1), `DurationEstimator` (Task 2)
- Produces:
  - `protocol SpeechProvider: Sendable` with `outputFormat`, `supportsIncrementalStreaming`, `recommendedCharacterCap`, `synthesize(text:voice:speed:) async throws -> Data`, `listVoices() async throws -> [Voice]`
  - `actor FakeProvider` with `Behavior` enum: `.normal`, `.empty`, `.short(fraction: Double)`, `.failing(SpeechError)`, `.slow(seconds: Double)`; plus `setBehavior(_:)`, `callCount`, `lastText`, `cancelledCount`

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/FakeProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

@Test func fakeProducesAudioProportionalToText() async throws {
    let fake = FakeProvider()
    let data = try await fake.synthesize(text: String(repeating: "a", count: 154),
                                         voice: "af_bella", speed: 1.0)
    let seconds = DurationEstimator().duration(ofBytes: data.count, format: fake.outputFormat)
    #expect(abs(seconds - 10.0) < 0.1)
}

@Test func fakeCanReturnEmptyAudio() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.empty)
    let data = try await fake.synthesize(text: "hello there", voice: "v", speed: 1.0)
    #expect(data.isEmpty)
}

@Test func fakeCanReturnShortAudio() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.short(fraction: 0.25))
    let text = String(repeating: "a", count: 154)
    let data = try await fake.synthesize(text: text, voice: "v", speed: 1.0)
    let seconds = DurationEstimator().duration(ofBytes: data.count, format: fake.outputFormat)
    #expect(abs(seconds - 2.5) < 0.1)
}

@Test func fakeCanThrow() async {
    let fake = FakeProvider()
    await fake.setBehavior(.failing(.httpStatus(code: 500, body: "boom")))
    await #expect(throws: SpeechError.self) {
        try await fake.synthesize(text: "x", voice: "v", speed: 1.0)
    }
}

@Test func fakeRecordsCallsAndRespondsToCancellation() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 5))
    let task = Task { try await fake.synthesize(text: "x", voice: "v", speed: 1.0) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    _ = try? await task.value
    #expect(await fake.cancelledCount == 1)
}

@Test func fakeListsVoices() async throws {
    let fake = FakeProvider()
    let voices = try await fake.listVoices()
    #expect(voices.contains(Voice(id: "af_bella", name: "af_bella")))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FakeProvider 2>&1 | tail -20`
Expected: FAIL — `cannot find 'FakeProvider' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MoxSpeakCore/SpeechProvider.swift`:

```swift
import Foundation

/// A text-to-speech engine.
///
/// "OpenAI-compatible" guarantees a request shape and nothing else — not sample rates,
/// not streaming semantics, not error payloads. Every one of those is declared here so
/// the session can adapt rather than assume.
public protocol SpeechProvider: Sendable {
    /// Exactly what `synthesize` returns. Validated against the first response.
    var outputFormat: AudioFormat { get }

    /// False when the engine only returns complete responses. Affects chunk sizing only.
    var supportsIncrementalStreaming: Bool { get }

    /// Largest input this engine handles reliably. An engine property, not a constant.
    var recommendedCharacterCap: Int { get }

    /// Synthesize one chunk. Must honor `Task` cancellation.
    func synthesize(text: String, voice: String, speed: Double) async throws -> Data

    func listVoices() async throws -> [Voice]
}

/// In-memory provider for tests. No network, no audio hardware.
public actor FakeProvider: SpeechProvider {

    public enum Behavior: Sendable {
        case normal
        case empty
        /// Returns this fraction of the audio the text should have produced.
        case short(fraction: Double)
        case failing(SpeechError)
        case slow(seconds: Double)
    }

    public nonisolated var outputFormat: AudioFormat { .kokoroPCM }
    public nonisolated var supportsIncrementalStreaming: Bool { true }
    public nonisolated var recommendedCharacterCap: Int { 150 }

    private var behavior: Behavior = .normal
    private let estimator = DurationEstimator()

    public private(set) var callCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var lastText: String?

    public init() {}

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    public func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        callCount += 1
        lastText = text

        switch behavior {
        case .failing(let error):
            throw error

        case .slow(let seconds):
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                cancelledCount += 1
                throw error
            }
            return audio(forCharacters: text.count, fraction: 1.0)

        case .empty:
            return Data()

        case .short(let fraction):
            return audio(forCharacters: text.count, fraction: fraction)

        case .normal:
            try Task.checkCancellation()
            return audio(forCharacters: text.count, fraction: 1.0)
        }
    }

    public func listVoices() async throws -> [Voice] {
        [Voice(id: "af_bella", name: "af_bella"), Voice(id: "af_sky", name: "af_sky")]
    }

    private func audio(forCharacters count: Int, fraction: Double) -> Data {
        let seconds = estimator.estimate(characterCount: count) * fraction
        let bytes = Int(seconds * Double(outputFormat.bytesPerSecond))
        // Silence is fine; only the byte count carries meaning in tests.
        return Data(count: max(0, bytes))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter FakeProvider 2>&1 | tail -20`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MoxSpeakCore/SpeechProvider.swift Tests/MoxSpeakCoreTests/FakeProviderTests.swift
git commit -m "feat(core): speech provider protocol and configurable fake provider"
```

---

### Task 6: OpenAICompatibleProvider

**Files:**
- Create: `Sources/MoxSpeakCore/OpenAICompatibleProvider.swift`
- Create: `Tests/MoxSpeakCoreTests/OpenAICompatibleProviderTests.swift`

**Interfaces:**
- Consumes: `SpeechProvider` (Task 5), `AudioFormat`, `Voice`, `SpeechError` (Task 1)
- Produces:
  - `struct EngineConfig: Sendable` with `baseURL: URL`, `model: String`, `apiKey: String?`, `outputFormat: AudioFormat`, `recommendedCharacterCap: Int`, `supportsIncrementalStreaming: Bool`, `requestTimeout: TimeInterval`, plus `static func kokoroLocal(port:) -> EngineConfig`
  - `struct OpenAICompatibleProvider: SpeechProvider` with `init(config: EngineConfig, session: URLSession = .shared)`
  - `func identityProbe() async -> Bool`

- [ ] **Step 1: Write the failing test**

These tests use a stub `URLProtocol` so no network is touched.

Create `Tests/MoxSpeakCoreTests/OpenAICompatibleProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func ok(_ data: Data, url: URL) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                     headerFields: ["Content-Type": "audio/pcm"])!, data)
}

// MARK: - Tests

@Test func sendsCorrectRequestBody() async throws {
    let url = URL(string: "http://localhost:8880")!
    nonisolated(unsafe) var captured: Data?
    StubURLProtocol.handler = { request in
        captured = request.httpBodyStreamData() ?? request.httpBody
        return ok(Data(count: 48000), url: request.url!)
    }
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                            session: stubbedSession())
    _ = try await provider.synthesize(text: "hello", voice: "af_bella", speed: 1.0)

    let json = try JSONSerialization.jsonObject(with: #require(captured)) as! [String: Any]
    #expect(json["input"] as? String == "hello")
    #expect(json["voice"] as? String == "af_bella")
    #expect(json["response_format"] as? String == "pcm")
    #expect(json["stream"] as? Bool == true)
    // unit_normalization defaults to false upstream and must be turned on.
    let norm = json["normalization_options"] as! [String: Any]
    #expect(norm["unit_normalization"] as? Bool == true)
}

@Test func returnsAudioBytes() async throws {
    StubURLProtocol.handler = { request in ok(Data(count: 96000), url: request.url!) }
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                            session: stubbedSession())
    let data = try await provider.synthesize(text: "hello", voice: "v", speed: 1.0)
    #expect(data.count == 96000)
}

@Test func mapsNonSuccessStatusToSpeechError() async {
    StubURLProtocol.handler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                         headerFields: nil)!, Data("server exploded".utf8))
    }
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                            session: stubbedSession())
    await #expect(throws: SpeechError.httpStatus(code: 500, body: "server exploded")) {
        try await provider.synthesize(text: "hello", voice: "v", speed: 1.0)
    }
}

@Test func parsesVoiceList() async throws {
    let payload = Data("""
    {"voices":[{"id":"af_bella","name":"af_bella"},{"id":"af_sky","name":"af_sky"}]}
    """.utf8)
    StubURLProtocol.handler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!, payload)
    }
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                            session: stubbedSession())
    let voices = try await provider.listVoices()
    #expect(voices.count == 2)
    #expect(voices.first?.id == "af_bella")
}

@Test func identityProbeRejectsAServiceThatIsNotATtsEngine() async {
    StubURLProtocol.handler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                         headerFields: ["Content-Type": "text/html"])!,
         Data("<html><body>hello from some other app</body></html>".utf8))
    }
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                            session: stubbedSession())
    let identified = await provider.identityProbe()
    #expect(identified == false)
}

@Test func identityProbeAcceptsAValidVoiceList() async {
    let payload = Data(#"{"voices":[{"id":"af_bella","name":"af_bella"}]}"#.utf8)
    StubURLProtocol.handler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!, payload)
    }
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                            session: stubbedSession())
    #expect(await provider.identityProbe() == true)
}

// Helper: URLProtocol receives the body as a stream for async uploads.
extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter OpenAICompatible 2>&1 | tail -20`
Expected: FAIL — `cannot find 'OpenAICompatibleProvider' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MoxSpeakCore/OpenAICompatibleProvider.swift`:

```swift
import Foundation

public struct EngineConfig: Sendable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var outputFormat: AudioFormat
    public var recommendedCharacterCap: Int
    public var supportsIncrementalStreaming: Bool
    public var requestTimeout: TimeInterval

    public init(baseURL: URL,
                model: String,
                apiKey: String? = nil,
                outputFormat: AudioFormat = .kokoroPCM,
                recommendedCharacterCap: Int = 150,
                supportsIncrementalStreaming: Bool = true,
                requestTimeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.outputFormat = outputFormat
        self.recommendedCharacterCap = recommendedCharacterCap
        self.supportsIncrementalStreaming = supportsIncrementalStreaming
        self.requestTimeout = requestTimeout
    }

    /// The bootstrapped local engine. The port is supplied by EngineSupervisor
    /// in the app-shell plan; there is no auto-discovery.
    public static func kokoroLocal(port: Int) -> EngineConfig {
        EngineConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                     model: "kokoro")
    }
}

/// Speaks the OpenAI `/v1/audio/speech` shape, which Kokoro-FastAPI, OpenAI, Groq and
/// most local servers all implement.
public struct OpenAICompatibleProvider: SpeechProvider {

    private let config: EngineConfig
    private let session: URLSession

    public init(config: EngineConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var outputFormat: AudioFormat { config.outputFormat }
    public var supportsIncrementalStreaming: Bool { config.supportsIncrementalStreaming }
    public var recommendedCharacterCap: Int { config.recommendedCharacterCap }

    public func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appending(path: "/v1/audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": config.model,
            "input": text,
            "voice": voice,
            "speed": speed,
            "response_format": responseFormatName,
            "stream": config.supportsIncrementalStreaming,
            // unit_normalization defaults to false upstream; "10KB" is unspoken without it.
            "normalization_options": ["normalize": true, "unit_normalization": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SpeechError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpeechError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpeechError.httpStatus(code: http.statusCode, body: body)
        }
        return data
    }

    public func listVoices() async throws -> [Voice] {
        var request = URLRequest(url: config.baseURL.appending(path: "/v1/audio/voices"))
        request.timeoutInterval = config.requestTimeout
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SpeechError.badResponse("voice list unavailable")
        }

        struct Payload: Decodable {
            struct Entry: Decodable { let id: String; let name: String? }
            let voices: [Entry]
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return decoded.voices.map { Voice(id: $0.id, name: $0.name ?? $0.id) }
    }

    /// Confirms this endpoint is actually a compatible TTS engine before any user text
    /// is sent to it. A port is not an identity.
    public func identityProbe() async -> Bool {
        do {
            let voices = try await listVoices()
            return !voices.isEmpty
        } catch {
            return false
        }
    }

    private var responseFormatName: String {
        config.outputFormat.isRawPCM ? "pcm" : "mp3"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter OpenAICompatible 2>&1 | tail -30`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MoxSpeakCore/OpenAICompatibleProvider.swift Tests/MoxSpeakCoreTests/OpenAICompatibleProviderTests.swift
git commit -m "feat(core): OpenAI-compatible provider with identity probe"
```

---

### Task 7: SpeechSession — generations and prefetch

**Files:**
- Create: `Sources/MoxSpeakCore/SpeechSession.swift`
- Create: `Tests/MoxSpeakCoreTests/SpeechSessionTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–5
- Produces:
  - `actor SpeechSession` with `init(provider:preparer:segmenter:estimator:validation:)`
  - `@discardableResult func speak(_ raw: String, voice: String, speed: Double) -> Int` (returns the generation; actor-isolated, so callers write `await session.speak(...)`)
  - `func cancelAll()` (actor-isolated; callers write `await session.cancelAll()`)
  - `var currentGeneration: Int`, `var chunks: [Chunk]`, `func state(of index: Int) -> ChunkState`
  - `func waitForRenderComplete() async`
  - `struct ValidationPolicy: Sendable` with `minimumDurationRatio: Double = 0.6`, `maxRetries: Int = 1`

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/SpeechSessionTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

private func makeSession(provider: some SpeechProvider,
                         policy: SpeechSession.ValidationPolicy = .init()) -> SpeechSession {
    SpeechSession(provider: provider,
                  preparer: TextPreparer(),
                  segmenter: Segmenter(),
                  estimator: DurationEstimator(),
                  validation: policy)
}

private let article = String(
    repeating: "This is a sentence of ordinary length that will be chunked. ", count: 12)

@Test func rendersEveryChunk() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak(article, voice: "af_bella", speed: 1.0)
    await session.waitForRenderComplete()

    let chunks = await session.chunks
    #expect(chunks.count > 1)
    for chunk in chunks {
        guard case .rendered = await session.state(of: chunk.id) else {
            Issue.record("chunk \(chunk.id) not rendered")
            return
        }
    }
}

@Test func advancesGenerationOnEachSpeak() async {
    let session = makeSession(provider: FakeProvider())
    let first = await session.speak("Hello there.", voice: "v", speed: 1.0)
    let second = await session.speak("Different text.", voice: "v", speed: 1.0)
    #expect(second > first)
}

@Test func staleResponsesAreDiscardedAfterReplace() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 2))
    let session = makeSession(provider: fake)

    _ = await session.speak(article, voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(50))

    await fake.setBehavior(.normal)
    let newGeneration = await session.speak("Completely different text.", voice: "v", speed: 1.0)
    await session.waitForRenderComplete()

    // The new generation's chunks are present and the old work committed nothing.
    #expect(await session.currentGeneration == newGeneration)
    let chunks = await session.chunks
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "Completely different text.")
}

@Test func cancelAllStopsInFlightWork() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 5))
    let session = makeSession(provider: fake)

    _ = await session.speak(article, voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(50))
    await session.cancelAll()

    #expect(await fake.cancelledCount >= 1)
}

@Test func emptyInputProducesNoChunks() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak("   ", voice: "v", speed: 1.0)
    #expect(await session.chunks.isEmpty)
}

@Test func appliesTextPreparationBeforeSegmenting() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak("## A **heading**", voice: "v", speed: 1.0)
    let chunks = await session.chunks
    #expect(chunks.first?.text == "A heading")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SpeechSession 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SpeechSession' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MoxSpeakCore/SpeechSession.swift`:

```swift
import Foundation

/// Orchestrates preparation, segmentation, synthesis and validation.
///
/// Every speak request gets a generation number. In-flight work carries the generation
/// it belongs to, and a response arriving under a stale generation is discarded rather
/// than committed. Without this, replace-while-playing and seeking race against work
/// that has already been abandoned.
public actor SpeechSession {

    public struct ValidationPolicy: Sendable {
        /// Audio shorter than this fraction of the estimate is treated as a failure.
        /// The backend silently truncates; see the spec's Known Issues.
        public var minimumDurationRatio: Double = 0.6
        public var maxRetries: Int = 1
        public init() {}
    }

    private let provider: any SpeechProvider
    private let preparer: TextPreparer
    private let segmenter: Segmenter
    private let estimator: DurationEstimator
    private let validation: ValidationPolicy

    public private(set) var currentGeneration = 0
    public private(set) var chunks: [Chunk] = []

    private var states: [Int: ChunkState] = [:]
    private var renderTasks: [Task<Void, Never>] = []

    public init(provider: any SpeechProvider,
                preparer: TextPreparer = TextPreparer(),
                segmenter: Segmenter = Segmenter(),
                estimator: DurationEstimator = DurationEstimator(),
                validation: ValidationPolicy = ValidationPolicy()) {
        self.provider = provider
        self.preparer = preparer
        self.segmenter = segmenter
        self.estimator = estimator
        self.validation = validation
    }

    public func state(of index: Int) -> ChunkState {
        states[index] ?? .pending
    }

    /// Replaces whatever is playing. Returns the new generation.
    @discardableResult
    public func speak(_ raw: String, voice: String, speed: Double) -> Int {
        cancelAll()

        currentGeneration += 1
        let generation = currentGeneration

        let prepared = preparer.prepare(raw)
        chunks = segmenter.segment(prepared)
        states = [:]
        for chunk in chunks { states[chunk.id] = .pending }

        startRendering(generation: generation, voice: voice, speed: speed)
        return generation
    }

    public func cancelAll() {
        for task in renderTasks { task.cancel() }
        renderTasks = []
    }

    /// Test and CLI helper: resolves once every render task has finished.
    public func waitForRenderComplete() async {
        let tasks = renderTasks
        for task in tasks { _ = await task.value }
    }

    // MARK: - Rendering

    /// Synthesis runs continuously ahead of playback, not one chunk ahead. At 13-20x
    /// realtime it outruns listening, which is what makes seeking feel instant.
    private func startRendering(generation: Int, voice: String, speed: Double) {
        for chunk in chunks {
            let task = Task { [weak self] in
                await self?.render(chunk: chunk,
                                   generation: generation,
                                   voice: voice,
                                   speed: speed)
            }
            renderTasks.append(task)
        }
    }

    private func render(chunk: Chunk, generation: Int, voice: String, speed: Double) async {
        guard generation == currentGeneration else { return }
        states[chunk.id] = .synthesizing

        do {
            let data = try await synthesizeValidated(chunk: chunk, voice: voice, speed: speed)
            // The generation may have advanced while this was in flight.
            guard generation == currentGeneration else { return }
            let duration = estimator.duration(ofBytes: data.count, format: provider.outputFormat)
            states[chunk.id] = .rendered(data: data, duration: duration)
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration else { return }
            states[chunk.id] = .failed(reason: "\(error)")
        }
    }

    /// Overridden in Task 8 to add retry-then-split recovery.
    fileprivate func synthesizeValidated(chunk: Chunk,
                                         voice: String,
                                         speed: Double) async throws -> Data {
        try await provider.synthesize(text: chunk.text, voice: voice, speed: speed)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SpeechSession 2>&1 | tail -30`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MoxSpeakCore/SpeechSession.swift Tests/MoxSpeakCoreTests/SpeechSessionTests.swift
git commit -m "feat(core): speech session with generation tokens and continuous prefetch"
```

---

### Task 8: SpeechSession — output validation and recovery

This is the task that makes the backend's silent-truncation bug visible. Without it, a
short or empty response presents to the user as "it just stopped reading."

**Files:**
- Modify: `Sources/MoxSpeakCore/SpeechSession.swift` (replace `synthesizeValidated`)
- Create: `Tests/MoxSpeakCoreTests/SpeechSessionValidationTests.swift`

**Interfaces:**
- Consumes: `SpeechSession` (Task 7), `FakeProvider.Behavior` (Task 5)
- Produces: no new public API; `synthesizeValidated` gains retry-then-split behavior, and `ChunkState.failed` becomes reachable through validation.

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/SpeechSessionValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import MoxSpeakCore

private func session(_ provider: some SpeechProvider) -> SpeechSession {
    SpeechSession(provider: provider,
                  preparer: TextPreparer(),
                  segmenter: Segmenter(),
                  estimator: DurationEstimator())
}

@Test func emptyAudioIsRetriedThenMarkedFailed() async {
    let fake = FakeProvider()
    await fake.setBehavior(.empty)
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to be failed")
        return
    }
    // One initial attempt plus one retry plus the split attempts.
    #expect(await fake.callCount >= 2)
}

@Test func shortAudioIsRetried() async {
    let fake = FakeProvider()
    await fake.setBehavior(.short(fraction: 0.2))
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    #expect(await fake.callCount >= 2)
    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to be failed after retries")
        return
    }
}

@Test func audioWithinToleranceIsAccepted() async {
    let fake = FakeProvider()
    // 80% of estimate is above the 0.6 default ratio.
    await fake.setBehavior(.short(fraction: 0.8))
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .rendered = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to be accepted")
        return
    }
    #expect(await fake.callCount == 1)
}

@Test func oneFailedChunkDoesNotStopTheOthers() async {
    // A provider that fails only the second chunk it is asked for.
    actor SelectiveProvider: SpeechProvider {
        nonisolated var outputFormat: AudioFormat { .kokoroPCM }
        nonisolated var supportsIncrementalStreaming: Bool { true }
        nonisolated var recommendedCharacterCap: Int { 150 }
        private var seen = 0
        private let estimator = DurationEstimator()

        func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
            seen += 1
            if text.contains("POISON") { return Data() }
            let seconds = estimator.estimate(characterCount: text.count)
            return Data(count: Int(seconds * 48000))
        }
        func listVoices() async throws -> [Voice] { [] }
    }

    let s = session(SelectiveProvider())
    let text = "First sentence is fine. POISON sentence fails here. Third sentence is fine too."
    _ = await s.speak(text, voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    let chunks = await s.chunks
    var rendered = 0
    var failed = 0
    for chunk in chunks {
        switch await s.state(of: chunk.id) {
        case .rendered: rendered += 1
        case .failed: failed += 1
        default: break
        }
    }
    #expect(rendered >= 1, "other chunks must still render")
    #expect(failed >= 1, "the poisoned chunk must be marked failed")
}

@Test func providerErrorsAreRecordedAsFailed() async {
    let fake = FakeProvider()
    await fake.setBehavior(.failing(.httpStatus(code: 500, body: "boom")))
    let s = session(fake)

    _ = await s.speak("A sentence.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .failed(let reason) = await s.state(of: 0) else {
        Issue.record("expected failed state")
        return
    }
    #expect(reason.contains("500"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SpeechSessionValidation 2>&1 | tail -30`
Expected: FAIL — empty and short audio are currently accepted, so the `.failed` expectations fail.

- [ ] **Step 3: Replace `synthesizeValidated` in `Sources/MoxSpeakCore/SpeechSession.swift`**

Delete the `fileprivate func synthesizeValidated` stub from Task 7 and put this in its place:

```swift
    // MARK: - Validation

    /// Synthesize with output validation.
    ///
    /// The backend can return HTTP 200 with truncated or entirely absent audio (see the
    /// spec's Known Issues). Comparing the returned duration against the character-count
    /// estimate is the only thing that makes that failure visible. Recovery ladder:
    /// retry as-is, then split in half and synthesize the pieces, then give up.
    private func synthesizeValidated(chunk: Chunk,
                                     voice: String,
                                     speed: Double) async throws -> Data {
        var attempt = 0
        while attempt <= validation.maxRetries {
            try Task.checkCancellation()
            let data = try await provider.synthesize(text: chunk.text, voice: voice, speed: speed)
            if isAcceptable(data: data, for: chunk.text) { return data }
            attempt += 1
        }

        // Halve and retry. Smaller inputs sit further inside the backend's working range.
        if let halves = splitInHalf(chunk.text) {
            var combined = Data()
            for piece in halves {
                try Task.checkCancellation()
                let data = try await provider.synthesize(text: piece, voice: voice, speed: speed)
                guard isAcceptable(data: data, for: piece) else {
                    throw SpeechError.shortAudio(
                        expected: estimator.estimate(characterCount: piece.count),
                        got: estimator.duration(ofBytes: data.count, format: provider.outputFormat))
                }
                combined.append(data)
            }
            return combined
        }

        throw SpeechError.emptyAudio
    }

    private func isAcceptable(data: Data, for text: String) -> Bool {
        guard !data.isEmpty else { return false }
        let expected = estimator.estimate(characterCount: text.count)
        guard expected > 0 else { return true }
        let got = estimator.duration(ofBytes: data.count, format: provider.outputFormat)
        return got / expected >= validation.minimumDurationRatio
    }

    /// Split at the word boundary nearest the middle. Returns nil when too short to split.
    private func splitInHalf(_ text: String) -> [String]? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return nil }
        let middle = words.count / 2
        return [words[..<middle].joined(separator: " "),
                words[middle...].joined(separator: " ")]
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SpeechSessionValidation 2>&1 | tail -30`
Expected: PASS — 5 tests.

- [ ] **Step 5: Run the whole suite to check nothing regressed**

Run: `swift test 2>&1 | tail -20`
Expected: PASS — all tests from Tasks 1–8.

- [ ] **Step 6: Commit**

```bash
git add Sources/MoxSpeakCore/SpeechSession.swift Tests/MoxSpeakCoreTests/SpeechSessionValidationTests.swift
git commit -m "feat(core): per-chunk audio validation with retry-then-split recovery"
```

---

### Task 9: PlaybackEngine and CLI

Deliverable: `moxspeak speak "some text"` produces sound from the speakers.

`PlaybackEngine` is deliberately thin because it cannot be honestly unit-tested — it
needs real audio hardware. Its tests cover only buffer conversion, which is pure.

**Files:**
- Create: `Sources/MoxSpeakCore/PlaybackEngine.swift`
- Create: `Sources/moxspeak/main.swift`
- Create: `Tests/MoxSpeakCoreTests/PlaybackEngineTests.swift`

**Interfaces:**
- Consumes: `AudioFormat` (Task 1), `SpeechSession` (Tasks 7–8)
- Produces:
  - `final class PlaybackEngine` with `init(format: AudioFormat) throws`, `func start() throws`, `func enqueue(_ data: Data) throws`, `func stop()`, `var rate: Float { get set }`
  - `static func buffer(from data: Data, format: AudioFormat) -> AVAudioPCMBuffer?`

- [ ] **Step 1: Write the failing test**

Create `Tests/MoxSpeakCoreTests/PlaybackEngineTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import MoxSpeakCore

@Test func convertsRawPCMBytesToABuffer() throws {
    // One second of silence: 48000 bytes at 24kHz 16-bit mono.
    let data = Data(count: 48000)
    let buffer = try #require(PlaybackEngine.buffer(from: data, format: .kokoroPCM))
    #expect(buffer.frameLength == 24000)
    #expect(buffer.format.channelCount == 1)
    #expect(buffer.format.sampleRate == 24000)
}

@Test func preservesSampleValues() throws {
    // Two frames: 0x0100 == 256, 0xFF7F == 32767 little-endian.
    var data = Data()
    data.append(contentsOf: [0x00, 0x01])
    data.append(contentsOf: [0xFF, 0x7F])
    let buffer = try #require(PlaybackEngine.buffer(from: data, format: .kokoroPCM))
    #expect(buffer.frameLength == 2)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect(abs(channel[0] - (256.0 / 32768.0)) < 0.0001)
    #expect(abs(channel[1] - (32767.0 / 32768.0)) < 0.0001)
}

@Test func rejectsOddLengthData() {
    // 16-bit samples cannot come in odd byte counts.
    #expect(PlaybackEngine.buffer(from: Data(count: 3), format: .kokoroPCM) == nil)
}

@Test func emptyDataProducesNoBuffer() {
    #expect(PlaybackEngine.buffer(from: Data(), format: .kokoroPCM) == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PlaybackEngine 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PlaybackEngine' in scope`.

- [ ] **Step 3: Write `Sources/MoxSpeakCore/PlaybackEngine.swift`**

```swift
import Foundation
import AVFoundation

/// Plays raw PCM through AVAudioEngine.
///
/// The TimePitch unit means playback speed changes are instant and pitch-corrected,
/// with no re-synthesis and no request to the engine. Playback speed and synthesis
/// speed are deliberately decoupled.
public final class PlaybackEngine: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AudioFormat
    private let processingFormat: AVAudioFormat

    public init(format: AudioFormat) throws {
        self.format = format
        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: AVAudioChannelCount(format.channels),
                                             interleaved: false) else {
            throw SpeechError.badResponse("unsupported audio format")
        }
        self.processingFormat = processing

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: processing)
        engine.connect(timePitch, to: engine.mainMixerNode, format: processing)
    }

    /// Playback rate. 1.0 is normal; pitch is preserved.
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    public func start() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        player.play()
    }

    public func enqueue(_ data: Data) throws {
        guard let buffer = Self.buffer(from: data, format: format) else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    /// Waits until everything scheduled has played. Used by the CLI.
    public func waitForDrain() async {
        while player.isPlaying, engine.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
            if player.lastRenderTime?.sampleTime == nil { break }
        }
    }

    /// Converts raw interleaved signed 16-bit little-endian samples to a float buffer.
    public static func buffer(from data: Data, format: AudioFormat) -> AVAudioPCMBuffer? {
        guard format.bitDepth == 16, !data.isEmpty else { return nil }
        let bytesPerFrame = (format.bitDepth / 8) * format.channels
        guard data.count % bytesPerFrame == 0 else { return nil }

        let frameCount = data.count / bytesPerFrame
        guard let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: format.sampleRate,
                                           channels: AVAudioChannelCount(format.channels),
                                           interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<format.channels {
                    let sample = Int16(littleEndian: samples[frame * format.channels + channel])
                    channels[channel][frame] = Float(sample) / 32768.0
                }
            }
        }
        return buffer
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PlaybackEngine 2>&1 | tail -20`
Expected: PASS — 4 tests.

- [ ] **Step 5: Write the CLI at `Sources/moxspeak/main.swift`**

```swift
import Foundation
import MoxSpeakCore

// Usage:
//   moxspeak speak "some text"          reads the argument
//   moxspeak speak -                    reads stdin
//   Options: --voice <id> --speed <x> --port <n> --voices

func failUsage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: moxspeak speak <text|-> [--voice af_bella] [--speed 1.0] [--port 8880]
           moxspeak voices [--port 8880]

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { failUsage() }
args.removeFirst()

func option(_ name: String, default fallback: String) -> String {
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else {
        return fallback
    }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

let voice = option("voice", default: "af_bella")
let speed = Double(option("speed", default: "1.0")) ?? 1.0
let port = Int(option("port", default: "8880")) ?? 8880

let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: port))

switch command {
case "voices":
    let voices = try await provider.listVoices()
    for v in voices { print(v.id) }

case "speak":
    guard let source = args.first else { failUsage() }
    let text: String
    if source == "-" {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        text = String(data: input, encoding: .utf8) ?? ""
    } else {
        text = source
    }

    guard await provider.identityProbe() else {
        FileHandle.standardError.write(Data(
            "error: no compatible TTS engine at 127.0.0.1:\(port)\n".utf8))
        exit(1)
    }

    let session = SpeechSession(provider: provider)
    let engine = try PlaybackEngine(format: provider.outputFormat)
    try engine.start()

    await session.speak(text, voice: voice, speed: speed)
    let chunks = await session.chunks
    guard !chunks.isEmpty else { exit(0) }

    // Play in order, waiting for each chunk to be ready. Synthesis of later chunks
    // continues in the background while earlier ones play.
    let started = Date()
    var firstSoundReported = false
    for chunk in chunks {
        var state = await session.state(of: chunk.id)
        while case .pending = state {
            try await Task.sleep(for: .milliseconds(20))
            state = await session.state(of: chunk.id)
        }
        while case .synthesizing = state {
            try await Task.sleep(for: .milliseconds(20))
            state = await session.state(of: chunk.id)
        }
        switch state {
        case .rendered(let data, _):
            if !firstSoundReported {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                FileHandle.standardError.write(Data("time to first sound: \(ms)ms\n".utf8))
                firstSoundReported = true
            }
            try engine.enqueue(data)
        case .failed(let reason):
            FileHandle.standardError.write(Data("chunk \(chunk.id) failed: \(reason)\n".utf8))
        default:
            break
        }
    }

    await engine.waitForDrain()
    engine.stop()

default:
    failUsage()
}
```

- [ ] **Step 6: Build and verify the whole suite passes**

```bash
cd /Users/guymorita/Dev/moxspeak
swift build 2>&1 | tail -20
swift test 2>&1 | tail -20
```
Expected: build succeeds, all tests pass.

- [ ] **Step 7: Hear it work**

The local Kokoro-FastAPI must be running on the given port.

```bash
swift run moxspeak voices --port 8880 | head -5
swift run moxspeak speak "It was a bright cold day in April, and the clocks were striking thirteen."
```
Expected: voices list prints; the sentence is spoken aloud; `time to first sound: NNNms` appears on stderr and is in the 600–1500ms range from the spec.

- [ ] **Step 8: Verify the validation guard catches the backend bug**

```bash
# Well over the reliable range for a single request, but the segmenter caps chunks
# at 150 chars, so this should speak completely rather than cutting off.
swift run moxspeak speak "$(head -c 2000 /usr/share/dict/words | tr '\n' ' ')" 2>&1 | tail -5
```
Expected: plays to completion. Any chunk the backend truncates is reported on stderr as
`chunk N failed:` rather than silently dropped. Zero such lines is the good outcome; the
point is that failures are visible either way.

- [ ] **Step 9: Commit**

```bash
git add Sources/MoxSpeakCore/PlaybackEngine.swift Sources/moxspeak/main.swift Tests/MoxSpeakCoreTests/PlaybackEngineTests.swift
git commit -m "feat(core): playback engine and moxspeak CLI"
```

---

## Done criteria for this plan

- `swift test` passes with all tests from Tasks 1–9.
- `swift run moxspeak speak "..."` speaks the text through the speakers.
- Time to first sound is reported and falls in the spec's 600–1500ms range.
- A chunk the backend truncates or drops is reported on stderr, never silently skipped.
- No AppKit, no Accessibility permission, no UI, no Xcode project.

## Deliberately deferred, with reasons

These are spec requirements this plan does not implement. They are recorded here so they
are not silently dropped.

- **Decoded-buffer memory accounting and spill-to-disk.** The spec caps in-memory audio
  and spills past it. It belongs to `SpeechSession`, which is a Plan 1 component, but it
  only bites on long documents played through the HUD, and the CLI plays straight
  through. Implement it at the start of Plan 2, before the HUD, as a contained addition
  to `SpeechSession`.
- **The mp3 decode path via `AVAudioConverter`.** `PlaybackEngine` here handles raw
  16-bit PCM only, which is what the default Kokoro engine emits. The provider already
  declares its format, so nothing has to change to add this — but an mp3-only engine
  will not play until it exists. Needed only when a second provider is added.
- **A non-streaming provider test.** `supportsIncrementalStreaming` is declared and
  threaded through to the request body, but nothing exercises the `false` path yet,
  because no configured engine sets it.

## What Plan 2 adds

`EngineSupervisor` (bootstrap, private port, supervision), `SelectionReader` (AX plus
pasteboard fallback), `HotkeyManager` with conflict detection, the menu bar item, the
HUD with its draggable position bar, the settings window with Keychain storage and
export/import, and ad-hoc signed `.app` packaging.
