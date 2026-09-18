import Testing
import Foundation
@testable import SpeakeasyApp

// EngineHealth is the one part of the app that is pure logic rather than AppKit, so it is
// the one part that can be tested honestly. Everything asserted here is asserted on the
// real type — no fakes, no clock, no network.

// MARK: - Empty and single-sample cases

@Test func aFreshHealthKnowsNothingAndSaysSo() {
    let health = EngineHealth()
    #expect(health.median == nil)
    #expect(health.status == .unknown)
    #expect(health.sampleCount == 0)
    // The distinction that matters: "not measured" must never render as "healthy".
    #expect(health.summary.contains("not measured"))
}

@Test func aSingleSampleIsItsOwnMedian() {
    var health = EngineHealth()
    health.record(timeToFirstSound: 1.4)
    #expect(health.median == 1.4)
    #expect(health.status == .healthy(median: 1.4))
}

@Test func aSingleSlowSampleIsEnoughToReportSlow() {
    // Deliberate: there is no minimum sample count before the app will say "slow". One
    // 6-second wait is already something the user felt, and staying quiet about it until
    // some quorum is reached is the silent-failure behavior this project exists to avoid.
    var health = EngineHealth()
    health.record(timeToFirstSound: 6.0)
    #expect(health.status == .slow(median: 6.0))
}

// MARK: - Median

@Test func oddCountsTakeTheMiddleSample() {
    var health = EngineHealth()
    for sample in [5.0, 1.0, 3.0] { health.record(timeToFirstSound: sample) }
    #expect(health.median == 3.0)
}

@Test func evenCountsAverageTheTwoMiddleSamples() {
    var health = EngineHealth()
    for sample in [1.0, 2.0, 4.0, 5.0] { health.record(timeToFirstSound: sample) }
    #expect(health.median == 3.0)
}

@Test func medianIgnoresArrivalOrder() {
    var ascending = EngineHealth()
    for sample in [1.0, 2.0, 9.0] { ascending.record(timeToFirstSound: sample) }

    var shuffled = EngineHealth()
    for sample in [9.0, 1.0, 2.0] { shuffled.record(timeToFirstSound: sample) }

    #expect(ascending.median == shuffled.median)
}

@Test func oneOutlierDoesNotCondemnAHealthyEngine() {
    // The reason this is a median and not a mean. A single 30-second stall among four
    // fast requests pushes the *mean* to 8.3s — past the threshold — while the engine is
    // plainly fine.
    var health = EngineHealth()
    for sample in [1.0, 1.2, 1.1, 30.0] { health.record(timeToFirstSound: sample) }
    #expect(health.status == .healthy(median: 1.15))
}

// MARK: - Rolling window

@Test func theWindowKeepsOnlyTheMostRecentSamples() {
    var health = EngineHealth(windowSize: 3)
    for sample in [1.0, 1.0, 1.0, 9.0, 9.0, 9.0] { health.record(timeToFirstSound: sample) }
    #expect(health.sampleCount == 3)
    #expect(health.median == 9.0, "the early healthy samples must have aged out")
}

@Test func anEngineThatDegradesIsEventuallyReportedSlow() {
    // The actual failure this exists to catch: the engine starts fast and rots as it
    // runs. Health must follow it down rather than averaging the whole session.
    var health = EngineHealth(windowSize: 4, slowThreshold: 2.5)
    for sample in [0.9, 1.0, 1.1, 1.0] { health.record(timeToFirstSound: sample) }
    #expect(health.status == .healthy(median: 1.0))

    for sample in [3.0, 3.4, 3.2, 3.6] { health.record(timeToFirstSound: sample) }
    guard case .slow(let median) = health.status else {
        Issue.record("expected slow, got \(health.status)")
        return
    }
    #expect(median > 2.5)
}

@Test func anEngineThatRecoversIsReportedHealthyAgain() {
    var health = EngineHealth(windowSize: 3, slowThreshold: 2.5)
    for sample in [5.0, 6.0, 7.0] { health.record(timeToFirstSound: sample) }
    #expect(health.status == .slow(median: 6.0))

    for sample in [1.0, 1.0, 1.0] { health.record(timeToFirstSound: sample) }
    #expect(health.status == .healthy(median: 1.0))
}

@Test func aDegenerateWindowSizeIsFlooredRatherThanDisablingReporting() {
    // A window of zero would silently make `record` a no-op and leave status stuck on
    // .unknown forever — health reporting that reports nothing, which is worse than none.
    for size in [0, -5] {
        var health = EngineHealth(windowSize: size)
        #expect(health.windowSize == 1)
        health.record(timeToFirstSound: 4.0)
        #expect(health.status == .slow(median: 4.0))
    }
}

// MARK: - Threshold

@Test func exactlyAtTheThresholdIsNotSlow() {
    // The boundary belongs to the healthy side. Pinned because "crosses the threshold"
    // is ambiguous in prose and must not be ambiguous in code.
    var health = EngineHealth(slowThreshold: 2.5)
    health.record(timeToFirstSound: 2.5)
    #expect(health.status == .healthy(median: 2.5))
}

@Test func justPastTheThresholdIsSlow() {
    var health = EngineHealth(slowThreshold: 2.5)
    health.record(timeToFirstSound: 2.51)
    guard case .slow = health.status else {
        Issue.record("expected slow, got \(health.status)")
        return
    }
}

@Test func theThresholdIsConfigurable() {
    var strict = EngineHealth(slowThreshold: 0.5)
    strict.record(timeToFirstSound: 1.0)
    #expect(strict.status == .slow(median: 1.0))

    var lenient = EngineHealth(slowThreshold: 10.0)
    lenient.record(timeToFirstSound: 1.0)
    #expect(lenient.status == .healthy(median: 1.0))
}

// MARK: - Unreachable is a different state from slow

@Test func unreachableOutranksAnyTimingVerdict() {
    var health = EngineHealth()
    health.record(timeToFirstSound: 0.5)
    #expect(health.status == .healthy(median: 0.5))

    health.markUnreachable("connection refused on 127.0.0.1:8880")
    #expect(health.status == .unreachable(reason: "connection refused on 127.0.0.1:8880"))
    #expect(health.summary.contains("unreachable"))
    #expect(health.summary.contains("8880"), "the summary must name what actually happened")
}

@Test func unreachableKeepsTheSamplesForWhenItComesBack() {
    var health = EngineHealth()
    health.record(timeToFirstSound: 1.0)
    health.markUnreachable("timed out")
    #expect(health.sampleCount == 1, "samples survive so recovery isn't a reset to unknown")

    health.markReachable()
    #expect(health.status == .healthy(median: 1.0))
}

@Test func aSuccessfulRequestClearsUnreachableOnItsOwn() {
    // The engine answering *is* the proof it is reachable; nothing should have to
    // remember to clear the flag separately.
    var health = EngineHealth()
    health.markUnreachable("connection refused")
    health.record(timeToFirstSound: 1.0)
    #expect(health.status == .healthy(median: 1.0))
}

@Test func slowAndUnreachableAreDistinguishableStates() {
    var slow = EngineHealth()
    slow.record(timeToFirstSound: 9.0)

    var gone = EngineHealth()
    gone.markUnreachable("connection refused")

    #expect(slow.status != gone.status)
    #expect(slow.summary != gone.summary)
}

// MARK: - What the menu actually reads

@Test func theSlowSummaryNamesTheNumberAndTheOneUsefulAction() {
    var health = EngineHealth(slowThreshold: 2.5)
    health.record(timeToFirstSound: 3.24)
    #expect(health.summary == "Voice engine is slow (3.2s) — restarting it may help")
}

@Test func theHealthySummaryNamesTheNumberToo() {
    var health = EngineHealth()
    health.record(timeToFirstSound: 1.23)
    #expect(health.summary == "Voice engine is responsive (1.2s)")
}

@Test func noSummaryPromisesAnActionTheAppCannotPerform() {
    // The app cannot restart the engine, so nothing may offer to. "restarting it may
    // help" is advice to the user; "click here to restart" would be a lie.
    var health = EngineHealth()
    health.markUnreachable("connection refused")
    let summaries = [EngineHealth().summary, health.summary]
    for summary in summaries {
        #expect(!summary.lowercased().contains("click"))
        #expect(!summary.lowercased().contains("retry"))
    }
}

@Test func durationsAreFormattedToOneDecimalWithAUnit() {
    #expect(EngineHealth.format(1.0) == "1.0s")
    #expect(EngineHealth.format(3.249) == "3.2s")
    #expect(EngineHealth.format(0.04) == "0.0s")
}
