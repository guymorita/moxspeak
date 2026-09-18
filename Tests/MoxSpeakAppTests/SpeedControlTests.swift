import Testing
@testable import MoxSpeakApp
import MoxSpeakCore

// `SpeedControl` is the pure half of the speed slider — see `SpeedControlView` for the
// AppKit half these tests cannot reach. Formatting, snapping and clamping are asserted
// directly here; the view itself was verified by hand (dragging mid-playback, typing an
// exact value, reopening the menu) as described in the speed-control report.

// MARK: - Formatting

@Test func wholeNumbersDropTheDecimal() {
    #expect(SpeedControl.format(1.0) == "1×")
    #expect(SpeedControl.format(2.0) == "2×")
    #expect(SpeedControl.format(3.0) == "3×")
}

@Test func nonWholeValuesKeepUpToTwoPlacesAndTrimTrailingZeros() {
    #expect(SpeedControl.format(1.25) == "1.25×")
    #expect(SpeedControl.format(1.5) == "1.5×")
    #expect(SpeedControl.format(0.75) == "0.75×")
    #expect(SpeedControl.format(1.2) == "1.2×")
}

@Test func formattingRoundsToTwoPlaces() {
    #expect(SpeedControl.format(1.333) == "1.33×")
    #expect(SpeedControl.format(1.337) == "1.34×")
}

@Test func everyBoundaryOfTheRangeFormatsCleanly() {
    #expect(SpeedControl.format(PlaybackEngine.rateRange.lowerBound) == "0.5×")
    #expect(SpeedControl.format(PlaybackEngine.rateRange.upperBound) == "3×")
}

// MARK: - Clamping

@Test func clampedRespectsPlaybackEnginesOwnRange() {
    #expect(SpeedControl.clamped(9.0) == PlaybackEngine.rateRange.upperBound)
    #expect(SpeedControl.clamped(0.01) == PlaybackEngine.rateRange.lowerBound)
    #expect(SpeedControl.clamped(1.3) == 1.3)
}

@Test func clampedLeavesTheEndpointsAlone() {
    #expect(SpeedControl.clamped(PlaybackEngine.rateRange.lowerBound) == PlaybackEngine.rateRange.lowerBound)
    #expect(SpeedControl.clamped(PlaybackEngine.rateRange.upperBound) == PlaybackEngine.rateRange.upperBound)
}

// MARK: - Snapping (the slider's fast path)

@Test func aDragThatLandsCloseToACommonValueSnapsToIt() {
    #expect(SpeedControl.snapped(1.01) == 1.0)
    #expect(SpeedControl.snapped(0.99) == 1.0)
    #expect(SpeedControl.snapped(1.48) == 1.5)
    #expect(SpeedControl.snapped(2.02) == 2.0)
}

@Test func aDragJustOutsideTheToleranceIsLeftPrecise() {
    let justOutside = 1.0 + SpeedControl.snapTolerance + 0.01
    #expect(SpeedControl.snapped(justOutside) == SpeedControl.clamped(justOutside))
    #expect(SpeedControl.snapped(justOutside) != 1.0)
}

@Test func everyCommonValueSnapsToItself() {
    for value in SpeedControl.commonValues {
        #expect(SpeedControl.snapped(value) == value)
    }
}

@Test func snappingAlsoClampsOutOfRangeInput() {
    // A slider cannot physically produce a value outside its own min/max, but the
    // function's contract should not depend on that — nothing here assumes it.
    #expect(SpeedControl.snapped(9.0) == PlaybackEngine.rateRange.upperBound)
    #expect(SpeedControl.snapped(-4.0) == PlaybackEngine.rateRange.lowerBound)
}

@Test func aMidwayDragBetweenTwoCommonValuesSnapsToNeither() {
    // Roughly halfway between 1.0 and 1.25, well outside tolerance of both.
    #expect(SpeedControl.snapped(1.12) == SpeedControl.clamped(1.12))
}
