import Testing
import Foundation
@testable import MoxSpeakApp

// `VoiceCatalog` is pure — identifiers in, strings and a tree out — which is the whole
// reason the menu's *shape* was decided there instead of inline in `MenuBarController`.
// Everything below is asserted on the real functions with real inputs; nothing here
// touches AppKit.
//
// The suite is in three parts:
//
//   1. the mapping itself (names, descriptions, and what happens to an identifier the
//      catalog has never heard of),
//   2. the catalog against the voices actually on disk — the half that catches a typo in
//      an identifier or a voice file added without a name, and which is also where the
//      17 deleted `_v0`/`_inno` files are held deleted,
//   3. the menu tree, including the property that matters most and is easiest to break
//      by accident: the raw identifier is what is stored and selected, whatever the row
//      happens to say.

// MARK: - Locating the shipped voices
//
// Deliberately not via `NativeModelAssets`: that lives in MoxSpeakNative and pulls MLX
// in behind it, and this suite has no business linking a tensor library to read a
// directory listing. Walking up from this file is the same trick
// `NativeModelAssets.repositoryModelsDirectory` uses, minus the dependency.

private func shippedVoiceIDs() -> [String]? {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("Models/voices", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: candidate.path)) ?? []
            return contents
                .filter { $0.hasSuffix(".safetensors") }
                .map { String($0.dropLast(".safetensors".count)) }
                .sorted()
        }
        let parent = dir.deletingLastPathComponent()
        if parent == dir { break }
        dir = parent
    }
    // A checkout with no models is a normal thing — they are gitignored and hundreds of
    // megabytes. The tests that need them skip.
    return nil
}

// MARK: - 1. The mapping

@Test func aVoiceReadsAsANameThenAnAccentThenACharacter() {
    #expect(VoiceCatalog.displayTitle(for: "af_bella") == "Bella · American, elegant and refined")
    #expect(VoiceCatalog.displayTitle(for: "am_fenrir") == "Fenrir · American, deep and authoritative")
    #expect(VoiceCatalog.displayTitle(for: "bf_emma") == "Emma · British, sophisticated")
}

/// The name comes first because the name is the part anyone remembers. Nothing in a row
/// may lead with the machine identifier.
@Test func noRowLeadsWithTheIdentifier() {
    for entry in VoiceCatalog.entries {
        #expect(entry.displayTitle.hasPrefix(entry.name))
        #expect(!entry.displayTitle.hasPrefix(entry.id))
    }
}

/// Every American voice says "American" and every British one says "British", and the
/// answer is derived from the identifier's documented `{language}{gender}_` prefix rather
/// than typed in twice.
@Test func accentAndGenderAgreeWithTheIdentifierPrefix() {
    for entry in VoiceCatalog.entries {
        let prefix = Array(entry.id.prefix(2))
        #expect(VoiceCatalog.Accent(identifierPrefix: prefix[0]) == entry.accent,
                "\(entry.id) is filed under \(entry.accent)")
        #expect((prefix[1] == "f" ? VoiceCatalog.Gender.female : .male) == entry.gender,
                "\(entry.id) is filed under \(entry.gender)")
        #expect(entry.displayTitle.contains(entry.accent.label))
    }
}

/// The single voice no source describes. It gets a name, an accent, and an honest
/// tooltip — not a guess. A wrong description actively sends someone to the wrong voice;
/// a missing one costs them a listen.
@Test func theOneUndocumentedVoiceGetsNoDescriptionRatherThanAnInventedOne() {
    let jadzia = VoiceCatalog.entry(id: "af_jadzia")
    #expect(jadzia?.description == nil)
    #expect(jadzia?.displayTitle == "Jadzia · American")
    #expect(jadzia?.tooltip.contains("no description") == true)

    // And it is the only one. A second undescribed voice appearing means a voice file was
    // added without anyone deciding what it sounds like.
    let undescribed = VoiceCatalog.entries.filter { $0.description == nil }.map(\.id)
    #expect(undescribed == ["af_jadzia"])
}

/// Hovering a row gives back the string that matches Kokoro's own documentation, a
/// `defaults read`, or a support thread — so renaming the rows costs nobody their ability
/// to cross-reference.
@Test func theTooltipAlwaysCarriesTheRawIdentifier() {
    for entry in VoiceCatalog.entries {
        #expect(entry.tooltip.hasPrefix(entry.id))
    }
}

/// `VOICES.md`'s grades measure training-data quality — source cleanliness, transcript
/// alignment, hours seen — and its own methodology section says so. Rendering "C+" beside
/// a voice would read as "this one sounds worse", which is a claim the grade does not
/// make. They may inform which voices get featured; they may not reach the screen.
@Test func gradesNeverReachTheInterface() {
    // Token-wise rather than substring-wise, because a bare "A" or "C" is a substring of
    // half the English language. A grade is only *visible* if it stands alone as a word.
    let grades = Set(VoiceCatalog.entries.compactMap(\.trainingDataGrade))
    let boundaries = CharacterSet(charactersIn: " \t\n·,.;:—-()[]\"'")

    for entry in VoiceCatalog.entries {
        for rendered in [entry.displayTitle, entry.tooltip] {
            let tokens = rendered.components(separatedBy: boundaries).filter { !$0.isEmpty }
            for token in tokens {
                #expect(!grades.contains(token),
                        "\(entry.id) renders the grade \(token) in \"\(rendered)\"")
            }
        }
    }

    // And the grades are real rather than a field nobody filled in — the featured set is
    // chosen from them, so an empty column would make that choice arbitrary.
    #expect(grades.count > 5)
}

/// An identifier with no entry gets itself back, verbatim. This is the OpenAI-compatible
/// engine's non-English voices: the app has no business naming `zf_xiaobei`, and guessing
/// at a prefix table it only half-confirmed would be worse than the raw string.
@Test func anUnknownIdentifierIsShownAsItself() {
    #expect(VoiceCatalog.displayTitle(for: "zf_xiaobei") == "zf_xiaobei")
    #expect(VoiceCatalog.shortName(for: "zf_xiaobei") == "zf_xiaobei")
    #expect(VoiceCatalog.entry(id: "zf_xiaobei") == nil)
}

@Test func theShortNameIsWhatTheParentRowSays() {
    #expect(VoiceCatalog.shortName(for: "am_michael") == "Michael")
    #expect(VoiceCatalog.shortName(for: "af_heart") == "Heart")
}

// MARK: - 2. The catalog against what is actually on disk

/// The requirement, stated directly: no voice the app ships may show up as a bare
/// identifier.
@Test func everyShippedVoiceHasAName() throws {
    let shipped = try #require(shippedVoiceIDs(), "no Models/voices in this checkout")
    for id in shipped {
        let entry = VoiceCatalog.entry(id: id)
        #expect(entry != nil, "\(id) is on disk with no catalog entry")
        #expect(entry?.name != id)
    }
}

/// The other direction, and the one that catches a typo. An entry for a voice that is not
/// on disk is a row the user can never reach — or worse, one that selects an identifier
/// the engine 404s on.
@Test func everyCatalogEntryIsAVoiceThatShips() throws {
    let shipped = Set(try #require(shippedVoiceIDs(), "no Models/voices in this checkout"))
    for entry in VoiceCatalog.entries {
        #expect(shipped.contains(entry.id), "\(entry.id) is in the catalog but not on disk")
    }
}

/// The 17 removed files, held removed.
///
/// `_v0*` are superseded earlier generations of voices already shipped (`af_v0bella` is
/// the previous `af_bella`), and `_inno` are voice-tuning outputs from Kokoro-FastAPI's
/// cloning feature rather than anything the model's authors released. Both arrived
/// through the server distribution, not the model, and both are exactly the kind of thing
/// a re-fetch quietly puts back — `Scripts/prepare-models.py` filters them, and this is
/// the check that notices if that ever stops working.
@Test func noSupersededOrClonedVariantsShip() throws {
    let shipped = try #require(shippedVoiceIDs(), "no Models/voices in this checkout")
    let variants = shipped.filter { $0.contains("_v0") || $0.hasSuffix("_inno") }
    #expect(variants.isEmpty, "these should not be bundled: \(variants)")
    #expect(shipped.count == VoiceCatalog.entries.count)
}

/// Featured is a recommendation made sight-unheard, so it is made from the only evidence
/// there is: `VOICES.md`'s training-data grades. Everything featured must be at least a C
/// — below that the table falls into D and F, where recommending blind is a coin flip.
@Test func everyFeaturedVoiceIsWellAboveTheBottomOfTheGradeTable() {
    let acceptable: Set<String> = ["A", "A-", "B+", "B", "B-", "C+", "C"]
    for id in VoiceCatalog.featuredIDs {
        let entry = VoiceCatalog.entry(id: id)
        #expect(entry != nil, "featured \(id) is not in the catalog")
        #expect(acceptable.contains(entry?.trainingDataGrade ?? ""),
                "featured \(id) grades \(entry?.trainingDataGrade ?? "nothing")")
    }
}

/// A featured set that is all one accent, or all one gender, is not a set of choices.
@Test func theFeaturedSetCoversBothAccentsAndBothGenders() {
    let featured = VoiceCatalog.featuredIDs.compactMap { VoiceCatalog.entry(id: $0) }
    #expect(featured.count == VoiceCatalog.featuredIDs.count)
    #expect(Set(featured.map(\.accent)) == Set(VoiceCatalog.Accent.allCases))
    #expect(Set(featured.map(\.gender)) == Set(VoiceCatalog.Gender.allCases))
    // Small enough to decide from. The point of featuring is that it is not the wall.
    #expect(featured.count <= 8)
}

// MARK: - 3. The menu tree

private func voiceIDs(in nodes: [VoiceCatalog.Node]) -> [String] {
    nodes.flatMap { node -> [String] in
        switch node {
        case .voice(let id, _, _): [id]
        case .group(_, let children): voiceIDs(in: children)
        case .header, .separator: []
        }
    }
}

private func titles(in nodes: [VoiceCatalog.Node]) -> [String] {
    nodes.flatMap { node -> [String] in
        switch node {
        case .voice(_, let title, _): [title]
        case .group(_, let children): titles(in: children)
        case .header, .separator: []
        }
    }
}

private func groupTitles(in nodes: [VoiceCatalog.Node]) -> [String] {
    nodes.compactMap { if case .group(let title, _) = $0 { title } else { nil } }
}

private let allShipped = VoiceCatalog.entries.map(\.id)

/// Nothing may go missing. Every voice the engine offers is reachable from the menu, even
/// the ones a level down.
@Test func everyOfferedVoiceIsReachable() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_michael")
    #expect(Set(voiceIDs(in: nodes)) == Set(allShipped))
}

/// The top level is the featured seven and two submenus, not twenty-nine rows. This is
/// the whole point of the exercise, so it is asserted as a number.
@Test func theTopLevelIsShortEnoughToDecideFrom() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_michael")
    let topLevelVoices = nodes.filter { if case .voice = $0 { true } else { false } }
    #expect(topLevelVoices.count == VoiceCatalog.featuredIDs.count)
    #expect(groupTitles(in: nodes) == ["More American voices", "More British voices"])
    #expect(nodes.count < 15)
}

@Test func theFeaturedVoicesComeFirstAndInTheOrderTheyWereChosen() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_michael")
    #expect(nodes.first == .header("Featured"))
    #expect(Array(voiceIDs(in: nodes).prefix(VoiceCatalog.featuredIDs.count))
            == VoiceCatalog.featuredIDs)
}

/// A featured voice is not repeated inside its accent group — which is why the groups are
/// titled "More …". Listing Bella under Featured and then silently omitting her from a
/// group called "American" would read as a missing voice.
@Test func aFeaturedVoiceAppearsExactlyOnce() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_michael")
    let ids = voiceIDs(in: nodes)
    #expect(ids.count == Set(ids).count)
    #expect(ids.count == allShipped.count)
}

/// The current voice must be visible without hunting. When it is featured it is already
/// at the top; when it is not, it is pinned above the featured set.
@Test func aNonFeaturedCurrentVoiceIsPinnedToTheTop() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "af_kore")
    #expect(nodes.first == .header("Current"))
    #expect(voiceIDs(in: nodes).first == "af_kore")
    // Pinned *and* still in its group, so the group is not missing a voice either.
    #expect(voiceIDs(in: nodes).filter { $0 == "af_kore" }.count == 2)
}

@Test func aFeaturedCurrentVoiceIsNotPinnedTwice() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_michael")
    #expect(nodes.first == .header("Featured"))
    #expect(voiceIDs(in: nodes).filter { $0 == "am_michael" }.count == 1)
}

/// The engine can be mid-load, or the server unreachable, and the app is still speaking
/// in *something*. Whatever that is stays named and marked.
@Test func aCurrentVoiceTheEngineDidNotOfferIsStillShown() {
    let nodes = VoiceCatalog.menu(available: ["af_bella", "af_kore"], current: "am_michael")
    #expect(voiceIDs(in: nodes).contains("am_michael"))
    #expect(nodes.first == .header("Current"))
}

/// The OpenAI-compatible engine serves whatever voice files are on that machine, in
/// languages the vendored G2P cannot phonemize. They stay reachable, under their own
/// identifiers, out of the way.
@Test func voicesTheCatalogDoesNotKnowGoIntoTheirOwnGroupUnderTheirRawNames() {
    let nodes = VoiceCatalog.menu(available: allShipped + ["zf_xiaobei", "jf_alpha"],
                                  current: "af_bella")
    #expect(groupTitles(in: nodes).last == "Other voices")
    #expect(titles(in: nodes).contains("zf_xiaobei"))
    #expect(voiceIDs(in: nodes).contains("jf_alpha"))
}

@Test func aSingleVoiceEngineStillProducesAUsableMenu() {
    let nodes = VoiceCatalog.menu(available: ["af_bella"], current: "af_bella")
    #expect(voiceIDs(in: nodes) == ["af_bella"])
    #expect(groupTitles(in: nodes).isEmpty)
}

// MARK: - The identifier is still the identifier

/// The contract that makes all of the above safe: renaming a row changes what is *shown*
/// and nothing about what is stored, sent to the engine, or resolved on the next launch.
/// If this ever stops holding, every existing preference breaks at once and silently.
@Test func theRawIdentifierIsWhatTheMenuSelects() {
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_michael")
    for case .voice(let id, let title, _) in flatten(nodes) {
        #expect(allShipped.contains(id))
        #expect(id != title)
        #expect(VoiceCatalog.displayTitle(for: id) == title)
    }
}

private func flatten(_ nodes: [VoiceCatalog.Node]) -> [VoiceCatalog.Node] {
    nodes.flatMap { node -> [VoiceCatalog.Node] in
        if case .group(_, let children) = node { return flatten(children) }
        return [node]
    }
}

/// End to end through the real store: the identifier behind a prettied-up row is written,
/// read back, and resolved to itself.
@Test func aChosenVoiceRoundTripsThroughSettingsAsItsIdentifier() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        for entry in VoiceCatalog.entries {
            settings.storedVoice = entry.id
            let reread = Settings(defaults: defaults)
            #expect(reread.storedVoice == entry.id)
            #expect(Settings.resolveVoice(stored: reread.storedVoice, available: allShipped)
                    == entry.id)
        }
    }
}

/// The migration this change actually creates. Seventeen voice files were deleted, so a
/// preference pointing at one of them is no longer a hypothetical — it is what happens on
/// the next launch of any install that had one selected. The stored value is left on disk
/// untouched (an engine that has it again restores it) and the session falls back to the
/// default rather than to nothing.
@Test func aStoredVoiceThatWasDeletedFallsBackToTheDefault() {
    for gone in ["af_v0bella", "am_v0michael", "bf_v0emma", "af_amelia_inno", "bm_atten_inno"] {
        #expect(!allShipped.contains(gone))
        #expect(Settings.resolveVoice(stored: gone, available: allShipped) == Settings.defaultVoice)
    }
}

@Test func aStoredVoiceThatWasDeletedIsStillNotForgotten() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        settings.storedVoice = "af_v0bella"
        // Resolving is what the app speaks with; it must never write its fallback back.
        #expect(Settings.resolveVoice(stored: settings.storedVoice, available: allShipped)
                == Settings.defaultVoice)
        #expect(Settings(defaults: defaults).storedVoice == "af_v0bella")
    }
}

/// The owner's stored voice, named explicitly because it is the one preference this
/// change was not allowed to disturb.
@Test func theStoredVoiceAmMichaelSurvivesTheDeletion() {
    #expect(allShipped.contains("am_michael"))
    #expect(Settings.resolveVoice(stored: "am_michael", available: allShipped) == "am_michael")
    #expect(VoiceCatalog.displayTitle(for: "am_michael")
            == "Michael · American, grounded and professional")
}

/// A deleted voice also has to be *displayable* on the way out: `applyVoiceList` flashes
/// the stored identifier at the user when it is gone, and the menu may briefly hold it as
/// the current voice before the list arrives. Neither path may crash or blank out.
@Test func aDeletedVoiceStillRendersWhileItIsBeingFallenBackFrom() {
    #expect(VoiceCatalog.displayTitle(for: "am_v0michael") == "am_v0michael")
    let nodes = VoiceCatalog.menu(available: allShipped, current: "am_v0michael")
    #expect(nodes.first == .header("Current"))
    #expect(voiceIDs(in: nodes).first == "am_v0michael")
}
