import AppKit
import MediaPlayer

/// Media-key control and the system's Now Playing display.
///
/// ## Why `MPRemoteCommandCenter` and not a key monitor
///
/// The obvious way to catch F8 is `NSEvent.addGlobalMonitorForEvents` on
/// `.systemDefined` events — and it requires Accessibility permission, which would cost
/// this app its entire "no prompts, no entitlements" property for one feature.
/// `MPRemoteCommandCenter` gets the same keys with no permission at all, because the
/// system routes them to whichever app currently holds Now Playing rather than letting
/// apps snoop the keyboard. Verified working from an unsigned, unprompted bundle.
///
/// Holding Now Playing is not a side effect to tolerate, it is the point: a user who
/// started a long article and walked away can stop it from the keyboard, from Control
/// Center, or from a headphone button, without finding the menu bar icon first. That is
/// what "operable without looking at the screen" means here.
@MainActor
final class NowPlayingController {

    /// Play/pause and the media key's toggle both land here. The app has one utterance at
    /// a time, so one toggle is the whole model.
    var onTogglePlayPause: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?

    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()

    /// What the media keys and the Control Center buttons move by. Fifteen seconds is
    /// what every podcast player uses, which makes it the interval people already expect
    /// from that button.
    static let skipSeconds: Double = 15

    /// Seek by a relative amount. Negative goes back.
    var onSkip: ((Double) -> Void)?
    /// Seek to an absolute position, from dragging the scrubber.
    var onScrub: ((TimeInterval) -> Void)?
    private var isActivated = false

    /// Wires the remote commands. Called once at launch.
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        // Only the commands actually implemented are enabled. Leaving the rest enabled
        // would advertise controls (seek, next track) that do nothing, which reads as a
        // broken app rather than a deliberately small one.
        enable(commandCenter.togglePlayPauseCommand) { [weak self] in self?.onTogglePlayPause?() }
        enable(commandCenter.playCommand) { [weak self] in self?.onTogglePlayPause?() }
        enable(commandCenter.pauseCommand) { [weak self] in self?.onTogglePlayPause?() }
        enable(commandCenter.stopCommand) { [weak self] in self?.onStop?() }

        // Skipping, in the OS's own controls rather than in a window of ours.
        //
        // This is the whole transport people asked for — a scrubber, and fifteen seconds
        // back — and macOS already draws it, on the lock screen, in Control Center, on a
        // paired set of AirPods, and under the media keys, which is where Apple Podcasts
        // puts exactly these two commands. Reading a long article is the case that wants
        // them, and it is the case where you are not looking at the screen.
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        enable(commandCenter.skipBackwardCommand) { [weak self] in
            self?.onSkip?(-Self.skipSeconds)
        }
        enable(commandCenter.skipForwardCommand) { [weak self] in
            self?.onSkip?(Self.skipSeconds)
        }
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.onScrub?(event.positionTime)
            return .success
        }

        // Track skipping is still nothing: there is one article, not a playlist, and a
        // control that does nothing reads as a broken app rather than a small one.
        for unsupported in [commandCenter.nextTrackCommand,
                            commandCenter.previousTrackCommand,
                            commandCenter.seekForwardCommand,
                            commandCenter.seekBackwardCommand] {
            unsupported.isEnabled = false
        }
        AppLog.write("now playing: remote commands installed "
                     + "(play/pause, stop, scrub, ±\(Int(Self.skipSeconds))s)")
    }

    /// Announces a new utterance. The title is a short prefix of the text being read, so
    /// Control Center shows what is actually playing rather than just an app name.
    func beginPlaying(title: String, rate: Float) {
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "MoxSpeak",
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: rate),
            MPMediaItemPropertyPlaybackDuration: NSNumber(value: 0.0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: 0.0),
        ]
        infoCenter.playbackState = .playing
    }

    /// Updates the timeline. Called on a slow timer while something is being read.
    ///
    /// `isLiveStream` used to be set here, and it is why there was no transport at all:
    /// a live stream has no duration by definition, so the system drew a title and a
    /// play button and nothing else. Reading is not a live stream — it has a known
    /// length and a position inside it — and saying so is the entire feature.
    ///
    /// Duration grows while synthesis is still running, because the engine reports what
    /// it actually holds rather than a prediction. Synthesis outruns playback by roughly
    /// an order of magnitude, so it settles a second or two in.
    func setProgress(elapsed: TimeInterval, duration: TimeInterval, rate: Float) {
        guard infoCenter.nowPlayingInfo != nil, duration > 0 else { return }
        infoCenter.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] =
            NSNumber(value: duration)
        infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            NSNumber(value: elapsed)
        infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] =
            NSNumber(value: rate)
    }

    func setPaused(_ paused: Bool) {
        guard infoCenter.nowPlayingInfo != nil else { return }
        infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] =
            NSNumber(value: paused ? 0.0 : 1.0)
        infoCenter.playbackState = paused ? .paused : .playing
    }

    /// Gives Now Playing back. Without this the system keeps showing a finished article
    /// as though it were still going, and media keys keep coming here instead of going
    /// to whatever the user actually wants to control.
    func clear() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    private func enable(_ command: MPRemoteCommand,
                        action: @escaping @MainActor @Sendable () -> Void) {
        command.isEnabled = true
        _ = command.addTarget(handler: Self.mainActorTarget(action))
    }

    /// Builds the command handler outside any actor, and hops to the main actor inside it.
    ///
    /// `addTarget(handler:)` is not declared `@Sendable`, so a closure written inline
    /// here would silently inherit `@MainActor` — and MediaPlayer does not document which
    /// thread it delivers remote commands on. A main-actor closure invoked from anywhere
    /// else is a real data race, and one the concurrency runtime traps at runtime. The
    /// explicit hop is correct from any thread and costs one queued task per keypress.
    private nonisolated static func mainActorTarget(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    /// A short, single-line prefix of the text, for the Now Playing title.
    nonisolated static func title(for text: String, limit: Int = 60) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > limit else {
            return flattened.isEmpty ? "Clipboard" : flattened
        }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
