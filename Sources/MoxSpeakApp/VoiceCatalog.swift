import Foundation

/// Turns Kokoro's voice identifiers into something a person can choose from.
///
/// The engine's identity for a voice is a string like `af_bella`, and that stays the
/// identity everywhere it matters — it is what gets stored in `UserDefaults`, what is
/// handed to `synthesize`, and what Kokoro's own documentation calls the voice. This type
/// changes nothing about that. It only decides what the *menu* says on top of it.
///
/// ## Why the raw identifier is unusable in a picker
///
/// `af`/`am`/`bf`/`bm` is `{language}{gender}` — a/b for American/British English, f/m for
/// female/male — which is documented in Kokoro's `VOICES.md` and is legible to precisely
/// nobody who has not read it. Shown 29 of them in a flat list, the rational move is to
/// keep whatever the default already was, which is what was happening.
///
/// So a row reads `Bella · American, elegant and refined`: the name first, because the
/// name is the part anyone remembers, then the accent, then a short character tag. The
/// identifier is not thrown away — it is the tooltip, so anyone cross-referencing
/// Kokoro's docs or a config file can still find it.
///
/// ## Where the descriptions come from
///
/// The draft set is `madeinoz67/madeinoz-voice-server`'s `VOICE_QUICK_REF` page
/// (https://madeinoz67.github.io/madeinoz-voice-server/VOICE_QUICK_REF/), which gives each
/// of the 28 official English Kokoro voices a two-or-three-word character tag. It is MIT
/// licensed:
///
/// > Copyright (c) madeinoz67 (see the repository's LICENSE for the full text).
/// >
/// > Permission is hereby granted, free of charge, to any person obtaining a copy of this
/// > software and associated documentation files (the "Software"), to deal in the Software
/// > without restriction, including without limitation the rights to use, copy, modify,
/// > merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
/// > permit persons to whom the Software is furnished to do so, subject to the following
/// > conditions: The above copyright notice and this permission notice shall be included
/// > in all copies or substantial portions of the Software.
///
/// It is a *draft*, and it is treated as one. The tags are one person's impressions with
/// no stated listening methodology, so they were tightened rather than copied: redundant
/// pairs collapsed (`"Musical, lyrical"` → `lyrical`), non-acoustic words dropped
/// (`"Artistic, dreamy"` → `dreamy`), and jargon moved out of the row and into the tooltip
/// (`bf_emma`'s "RP" is not something to make a stranger decode mid-decision).
///
/// **Nothing here is invented.** `af_jadzia` ships with the app and appears in neither
/// `VOICES.md` nor the quick reference, so it gets a name and an accent and no
/// description. A wrong description is worse than a missing one: a missing one costs the
/// user a listen, a wrong one sends them to the wrong voice and they do not find out for
/// a paragraph.
///
/// ## What the grades are, and what they are not
///
/// `trainingDataGrade` is Kokoro's `VOICES.md` "Overall Grade". Its own methodology
/// section says it estimates *the quality and quantity of a voice's training data* —
/// source recording cleanliness, transcript alignment, hours seen — and states plainly
/// that "subjectively, voices will sound better or worse to different people." It is not
/// an audio-quality score and it is **never rendered into the interface**; labelling a row
/// "C+" would tell the user something false. It is here for one purpose: picking which
/// handful of voices to put in front of someone first, on the reasoning that a voice
/// trained on more and cleaner audio is a better bet to recommend blind.
enum VoiceCatalog {

    // MARK: - Types

    /// American or British. The only two Kokoro accents this app ships, because the
    /// vendored MisakiSwift carries the US English lexicon only.
    enum Accent: String, Sendable, CaseIterable {
        case american
        case british

        var label: String {
            switch self {
            case .american: "American"
            case .british: "British"
            }
        }

        /// The first character of a Kokoro identifier, per `VOICES.md`'s
        /// `{language}{gender}_{name}` scheme.
        init?(identifierPrefix: Character) {
            switch identifierPrefix {
            case "a": self = .american
            case "b": self = .british
            default: return nil
            }
        }
    }

    enum Gender: String, Sendable, CaseIterable {
        case female
        case male

        var label: String {
            switch self {
            case .female: "Female"
            case .male: "Male"
            }
        }
    }

    /// One shipped voice, as the menu needs to know it.
    struct Entry: Sendable, Equatable {
        /// The engine's identity, unchanged. `af_bella`.
        let id: String
        /// What a person calls it. `Bella`.
        let name: String
        let accent: Accent
        let gender: Gender
        /// A short character tag, or nil when no source describes this voice. Lowercase
        /// and fragmentary on purpose — it is the tail of "Bella · American, …", not a
        /// sentence.
        let description: String?
        /// `VOICES.md`'s overall grade. Training-data quality, never shown. See the type
        /// doc.
        let trainingDataGrade: String?
        /// Anything worth saying that does not belong in a one-line row: the accent
        /// jargon, or why a voice has no description.
        let footnote: String?

        /// `Bella · American, elegant and refined` — or `Jadzia · American` when nothing
        /// describes it.
        var displayTitle: String {
            guard let description else { return "\(name) · \(accent.label)" }
            return "\(name) · \(accent.label), \(description)"
        }

        /// What hovering the row says. Always leads with the identifier, because that is
        /// the string that matches Kokoro's documentation, a `defaults read`, or a
        /// support thread.
        var tooltip: String {
            guard let footnote else { return id }
            return "\(id) — \(footnote)"
        }
    }

    // MARK: - The catalog

    /// The 29 voices the app ships, in identifier order.
    ///
    /// Grades are `VOICES.md`'s, transcribed. Descriptions are the madeinoz67 draft,
    /// tightened — see the type doc for the licence and for the editing rules applied.
    static let entries: [Entry] = [
        // --- American female -------------------------------------------------------
        Entry(id: "af_heart", name: "Heart", accent: .american, gender: .female,
              description: "warm and friendly", trainingDataGrade: "A",
              footnote: "Kokoro's own documented default voice"),
        Entry(id: "af_bella", name: "Bella", accent: .american, gender: .female,
              description: "elegant and refined", trainingDataGrade: "A-",
              footnote: "MoxSpeak's default, and the one the Kokoro community tends to "
                      + "reach for"),
        Entry(id: "af_nicole", name: "Nicole", accent: .american, gender: .female,
              description: "professional", trainingDataGrade: "B-", footnote: nil),
        Entry(id: "af_aoede", name: "Aoede", accent: .american, gender: .female,
              description: "lyrical", trainingDataGrade: "C+", footnote: nil),
        Entry(id: "af_kore", name: "Kore", accent: .american, gender: .female,
              description: "soft and gentle", trainingDataGrade: "C+", footnote: nil),
        Entry(id: "af_sarah", name: "Sarah", accent: .american, gender: .female,
              description: "clear and articulate", trainingDataGrade: "C+", footnote: nil),
        Entry(id: "af_nova", name: "Nova", accent: .american, gender: .female,
              description: "dreamy", trainingDataGrade: "C", footnote: nil),
        Entry(id: "af_alloy", name: "Alloy", accent: .american, gender: .female,
              description: "crisp and modern", trainingDataGrade: "C", footnote: nil),
        Entry(id: "af_sky", name: "Sky", accent: .american, gender: .female,
              description: "bright and energetic", trainingDataGrade: "C-", footnote: nil),
        Entry(id: "af_jessica", name: "Jessica", accent: .american, gender: .female,
              description: "expressive", trainingDataGrade: "D", footnote: nil),
        Entry(id: "af_river", name: "River", accent: .american, gender: .female,
              description: "calm and flowing", trainingDataGrade: "D", footnote: nil),
        // The one voice on disk that no source covers. Not in `VOICES.md`'s table of 28
        // and not in the madeinoz67 quick reference, so it gets no description rather
        // than a guessed one. Its accent and gender are read from the identifier, which
        // *is* documented.
        Entry(id: "af_jadzia", name: "Jadzia", accent: .american, gender: .female,
              description: nil, trainingDataGrade: nil,
              footnote: "no description — this voice is in neither Kokoro's VOICES.md "
                      + "nor the reference this app's descriptions come from"),

        // --- American male ---------------------------------------------------------
        Entry(id: "am_fenrir", name: "Fenrir", accent: .american, gender: .male,
              description: "deep and authoritative", trainingDataGrade: "C+", footnote: nil),
        Entry(id: "am_michael", name: "Michael", accent: .american, gender: .male,
              description: "grounded and professional", trainingDataGrade: "C+", footnote: nil),
        Entry(id: "am_puck", name: "Puck", accent: .american, gender: .male,
              description: "playful", trainingDataGrade: "C+", footnote: nil),
        Entry(id: "am_echo", name: "Echo", accent: .american, gender: .male,
              description: "resonant", trainingDataGrade: "D", footnote: nil),
        Entry(id: "am_eric", name: "Eric", accent: .american, gender: .male,
              description: "friendly and warm", trainingDataGrade: "D", footnote: nil),
        Entry(id: "am_liam", name: "Liam", accent: .american, gender: .male,
              description: "clear and confident", trainingDataGrade: "D", footnote: nil),
        Entry(id: "am_onyx", name: "Onyx", accent: .american, gender: .male,
              description: "bold and strong", trainingDataGrade: "D", footnote: nil),
        Entry(id: "am_santa", name: "Santa", accent: .american, gender: .male,
              description: "jolly and warm", trainingDataGrade: "D-", footnote: nil),
        Entry(id: "am_adam", name: "Adam", accent: .american, gender: .male,
              description: "youthful and energetic", trainingDataGrade: "F+", footnote: nil),

        // --- British female --------------------------------------------------------
        Entry(id: "bf_emma", name: "Emma", accent: .british, gender: .female,
              description: "sophisticated", trainingDataGrade: "B-",
              footnote: "received pronunciation"),
        Entry(id: "bf_isabella", name: "Isabella", accent: .british, gender: .female,
              description: "elegant and proper", trainingDataGrade: "C", footnote: nil),
        Entry(id: "bf_alice", name: "Alice", accent: .british, gender: .female,
              description: "clear and well-spoken", trainingDataGrade: "D", footnote: nil),
        Entry(id: "bf_lily", name: "Lily", accent: .british, gender: .female,
              description: "soft and gentle", trainingDataGrade: "D", footnote: nil),

        // --- British male ----------------------------------------------------------
        Entry(id: "bm_fable", name: "Fable", accent: .british, gender: .male,
              description: "warm storyteller", trainingDataGrade: "C", footnote: nil),
        Entry(id: "bm_george", name: "George", accent: .british, gender: .male,
              description: "authoritative", trainingDataGrade: "C",
              footnote: "received pronunciation"),
        Entry(id: "bm_lewis", name: "Lewis", accent: .british, gender: .male,
              description: "confident and articulate", trainingDataGrade: "D+", footnote: nil),
        Entry(id: "bm_daniel", name: "Daniel", accent: .british, gender: .male,
              description: "clear and professional", trainingDataGrade: "D", footnote: nil),
    ]

    /// The handful put in front of the user first, in the order they appear.
    ///
    /// Chosen on two axes, neither of which is "what sounds nicest" — nobody has listened
    /// to all 29 and said so:
    ///
    /// 1. **Training-data grade.** `af_heart` (A) and `af_bella` (A-) are the top two of
    ///    the whole table, `af_nicole` and `bf_emma` (B-) the next; `am_fenrir` and
    ///    `am_michael` (C+) are jointly the best-graded American men, and `bm_fable` (C)
    ///    is tied for the best-graded British man. Below that the table falls off a cliff
    ///    into D and F, and recommending from there sight-unheard would be a coin flip.
    /// 2. **Distinctiveness.** Seven rows that all read "clear and professional" is not a
    ///    choice, it is seven of the same thing. So: warm, refined, professional, deep,
    ///    grounded, sophisticated, storytelling — and both accents and both genders, so
    ///    whatever the user came in wanting, something here is in that direction.
    ///
    /// `am_puck` is the notable omission at C+: "playful" is a narrow brief for a
    /// text-to-speech utility that mostly reads articles, and Fenrir and Michael already
    /// carry American male.
    static let featuredIDs = [
        "af_heart", "af_bella", "af_nicole",
        "am_michael", "am_fenrir",
        "bf_emma", "bm_fable",
    ]

    private static let byID: [String: Entry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0) }
    )

    static func entry(id: String) -> Entry? { byID[id] }

    /// What the menu row for this identifier should say.
    ///
    /// An identifier with no catalog entry gets itself back, verbatim. That is not a
    /// fallback that should ever fire for the bundled engine — `everyShippedVoiceHasAName`
    /// pins that — but the OpenAI-compatible engine serves whatever voice files happen to
    /// be on that machine, including non-English ones this app has no business naming.
    /// Showing `zf_xiaobei` as `zf_xiaobei` is honest; inventing "Xiaobei · Mandarin" from
    /// a prefix table we only half-confirmed would not be.
    static func displayTitle(for id: String) -> String {
        entry(id: id)?.displayTitle ?? id
    }

    /// Just the name — `Bella` — for the places one word is all that fits, like the
    /// parent menu row that names the current choice.
    static func shortName(for id: String) -> String {
        entry(id: id)?.name ?? id
    }

    // MARK: - Menu structure

    /// One row of the voice menu, decided here rather than in AppKit so the shape of the
    /// menu is something a test can assert on.
    ///
    /// Deliberately only the four cases `NSMenu` renders for free. Every row this
    /// produces is a plain `NSMenuItem`, which takes its text inset from AppKit — a
    /// custom view would have to measure and reproduce that inset by hand, which is
    /// exactly the fight `SpeedControlView` had to have and there is no reason to have it
    /// twice.
    enum Node: Equatable {
        /// A disabled label. Not selectable, just a heading over the rows beneath it.
        case header(String)
        case separator
        /// A selectable voice. `title` is what it says, `tooltip` what hovering says.
        case voice(id: String, title: String, tooltip: String)
        /// A submenu.
        case group(title: String, children: [Node])
    }

    /// Builds the voice menu for the voices an engine actually offers.
    ///
    /// The shape, and the reason for it: 29 flat rows is a wall, and a wall gets scrolled
    /// past rather than read. So the first thing in the menu is seven voices worth trying
    /// — see `featuredIDs` — and everything else is one level down, split by the axis
    /// people actually choose on, which is accent. That is ten rows at the top level
    /// instead of twenty-nine, and the ten are ordered by usefulness rather than by
    /// alphabet.
    ///
    /// The submenus are titled "More …" rather than "American"/"British" on purpose: a
    /// featured voice is *not* repeated inside its accent group, and a menu that lists
    /// Bella under Featured and then omits her from "American" would read as a bug.
    /// "More American voices" promises exactly what it contains.
    ///
    /// The current voice is pinned to the top of the menu whenever it is not one of the
    /// featured seven, so "which one am I on" is answerable without opening a submenu and
    /// hunting for a checkmark. (The caller also names it on the parent row.)
    ///
    /// - Parameters:
    ///   - available: identifiers the engine offers, in whatever order it gave them.
    ///   - current: the identifier in use. May legitimately not be in `available` — the
    ///     engine can be mid-load, or unreachable — in which case it is still pinned and
    ///     marked, because it is still what the app will speak with.
    static func menu(available: [String], current: String) -> [Node] {
        let known = Set(entries.map(\.id))
        let offered = Set(available)

        let featured = featuredIDs.filter { offered.contains($0) }
        let featuredSet = Set(featured)

        var nodes: [Node] = []

        // The current voice, when it is not already the first thing the user sees.
        if !featuredSet.contains(current) {
            nodes.append(.header("Current"))
            nodes.append(voiceNode(current))
            nodes.append(.separator)
        }

        if !featured.isEmpty {
            nodes.append(.header("Featured"))
            nodes.append(contentsOf: featured.map(voiceNode))
        }

        var groups: [Node] = []
        for accent in Accent.allCases {
            let rest = entries
                .filter { $0.accent == accent && offered.contains($0.id) && !featuredSet.contains($0.id) }
            guard !rest.isEmpty else { continue }

            var children: [Node] = []
            for gender in Gender.allCases {
                let inGender = rest.filter { $0.gender == gender }.sorted { $0.name < $1.name }
                guard !inGender.isEmpty else { continue }
                if !children.isEmpty { children.append(.separator) }
                children.append(.header(gender.label))
                children.append(contentsOf: inGender.map { voiceNode($0.id) })
            }
            groups.append(.group(title: "More \(accent.label) voices", children: children))
        }

        // Whatever the engine offers that this app has no name for. The bundled engine
        // has none of these; the OpenAI-compatible one has dozens, in languages Kokoro's
        // vendored G2P cannot phonemize anyway. They stay reachable and stay honest —
        // listed under their own identifiers, one level down, out of the way of the
        // English voices that are the point of this menu.
        let unnamed = available.filter { !known.contains($0) }.sorted()
        if !unnamed.isEmpty {
            groups.append(.group(title: "Other voices", children: unnamed.map(voiceNode)))
        }

        if !groups.isEmpty {
            if !nodes.isEmpty { nodes.append(.separator) }
            nodes.append(contentsOf: groups)
        }

        return nodes
    }

    private static func voiceNode(_ id: String) -> Node {
        .voice(id: id, title: displayTitle(for: id), tooltip: entry(id: id)?.tooltip ?? id)
    }
}
