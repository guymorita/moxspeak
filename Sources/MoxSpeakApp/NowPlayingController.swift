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

        for unsupported in [commandCenter.nextTrackCommand,
                            commandCenter.previousTrackCommand,
                            commandCenter.seekForwardCommand,
                            commandCenter.seekBackwardCommand,
                            commandCenter.changePlaybackPositionCommand] {
            unsupported.isEnabled = false
        }
        AppLog.write("now playing: remote commands installed")
    }

    /// Announces a new utterance. The title is a short prefix of the text being read, so
    /// Control Center shows what is actually playing rather than just an app name.
    func beginPlaying(title: String, rate: Float) {
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "MoxSpeak",
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: rate),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: true),
        ]
        infoCenter.playbackState = .playing
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
