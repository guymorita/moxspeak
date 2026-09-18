import Testing
import Foundation
@testable import MoxSpeakCore

/// Short enough to survive segmentation as a single chunk, so `lastText` is the whole thing.
private let money = "It cost $5."

private func session(_ provider: some SpeechProvider) -> SpeechSession {
    SpeechSession(provider: provider)
}

/// The regression guard this pair exists for: Kokoro-FastAPI normalizes server-side, and a
/// session that normalized on its way out would send text the server then normalizes a second
/// time — "$5" to "five dollars" to "five dollars dollars". A provider that declares it does
/// not want normalization must receive its text untouched by `TextNormalizer`.
@Test func providerThatDeclinesNormalizationGetsRawText() async {
    let fake = FakeProvider(requiresTextNormalization: false)
    let s = session(fake)
    _ = await s.speak(money, voice: "af_bella")
    await s.waitForRenderComplete()

    #expect(await fake.lastText == "It cost $5.")
}

@Test func providerThatRequiresNormalizationGetsExpandedText() async {
    let fake = FakeProvider(requiresTextNormalization: true)
    let s = session(fake)
    _ = await s.speak(money, voice: "af_bella")
    await s.waitForRenderComplete()

    #expect(await fake.lastText == "It cost five dollars.")
}

/// The same session, the same text, the two declarations: whatever else changes between two
/// providers, the decision to normalize tracks this one flag and nothing else.
@Test func normalizationTracksOnlyTheProviderDeclaration() async {
    let text = "Meet Dr. Chen at 3:30 on 2024-01-15."

    let plain = FakeProvider(requiresTextNormalization: false)
    let plainSession = session(plain)
    _ = await plainSession.speak(text, voice: "v")
    await plainSession.waitForRenderComplete()

    let expanding = FakeProvider(requiresTextNormalization: true)
    let expandingSession = session(expanding)
    _ = await expandingSession.speak(text, voice: "v")
    await expandingSession.waitForRenderComplete()

    #expect(await plain.lastText == text)
    #expect(await expanding.lastText == "Meet Doctor Chen at three thirty on January fifteenth twenty twenty four.")
}

/// The provider that exists today is the one that must never be normalized for.
@Test func openAICompatibleProviderDeclinesNormalization() {
    let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880))
    #expect(provider.requiresTextNormalization == false)
}

/// Preparation is not conditional. A provider that declines normalization still gets markdown
/// stripped, because document formatting is never speech whichever engine is downstream.
@Test func preparationRunsEvenWhenNormalizationDoesNot() async {
    let fake = FakeProvider(requiresTextNormalization: false)
    let s = session(fake)
    _ = await s.speak("It cost **$5**.", voice: "v")
    await s.waitForRenderComplete()

    #expect(await fake.lastText == "It cost $5.")
}
