import Foundation

/// Observes the voice engine from the outside, and says what it sees in plain words.
///
/// The app deliberately does not manage the engine process. It did not start it, it does
/// not know how, and it cannot restart it — real supervision belongs to a later
/// `EngineSupervisor`. What it *can* do is notice when the engine has gone bad and say
/// so, because the failure mode here is quiet: the backend leaks roughly 28 MB per
/// request and its slow-request ratio climbs over hours of uptime, so a session that
/// started snappy degrades into multi-second waits without ever returning an error.
/// Time-to-first-sound is the one number that makes that visible from this side of the
/// socket.
///
/// The window is a rolling one because only recent behavior is evidence: an engine that
/// was fast an hour ago and is slow now is a slow engine, and an average over the whole
/// session would take hours to admit it. The median, not the mean, because a single
/// 30-second outlier should not condemn an otherwise healthy engine — and because the
/// documented failure pattern is a rising *ratio* of slow requests, which is exactly what
/// a median crosses and a mean only drifts toward.
///
/// This type is pure: no clock, no network, no I/O. Everything it knows, a caller told it.
struct EngineHealth: Sendable {

    /// What the menu should say about the engine, in precedence order.
    enum Status: Equatable, Sendable {
        /// Nothing has been measured yet. Not a claim of health.
        case unknown
        /// Reachable, and the median time-to-first-sound is within threshold.
        case healthy(median: TimeInterval)
        /// Reachable, but the median time-to-first-sound has crossed the threshold.
        case slow(median: TimeInterval)
        /// Not reachable at all. Outranks every timing-based verdict: stale timings from
        /// before the engine disappeared say nothing useful about an engine that is gone.
        case unreachable(reason: String)
    }

    /// How many recent measurements count as "recent".
    ///
    /// Small enough that a genuine slowdown shows up within a handful of requests rather
    /// than being diluted by a long history of healthy ones.
    let windowSize: Int

    /// A median time-to-first-sound strictly above this is reported as slow.
    ///
    /// 2.5s is the default because measured healthy first-chunk latency against this
    /// backend is around 2s; a median past that is the engine having drifted, not a
    /// document being long. A median exactly at the threshold is *not* slow — the
    /// boundary belongs to the healthy side, and the tests pin that.
    let slowThreshold: TimeInterval

    private var samples: [TimeInterval] = []
    private var unreachableReason: String?

    init(windowSize: Int = 8, slowThreshold: TimeInterval = 2.5) {
        // A zero or negative window would make `record` a no-op and the status
        // permanently `.unknown` — health reporting that silently reports nothing is
        // worse than none, so the window is floored at one sample.
        self.windowSize = max(1, windowSize)
        self.slowThreshold = slowThreshold
    }

    // MARK: - Recording

    /// Records one successful request's time from "speak" to the first audible byte.
    ///
    /// Recording a measurement also clears any unreachable state: the engine just
    /// answered, so whatever it was, it is not unreachable now.
    mutating func record(timeToFirstSound seconds: TimeInterval) {
        unreachableReason = nil
        samples.append(seconds)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
    }

    /// Records that the engine could not be reached, and why.
    ///
    /// Timing samples are kept rather than discarded. They are not used while
    /// unreachable — `.unreachable` outranks them — but if the engine comes back they
    /// are still the most recent thing known about how fast it is, and throwing them
    /// away would reset the app to `.unknown` for no gain.
    mutating func markUnreachable(_ reason: String) {
        unreachableReason = reason
    }

    /// Clears unreachable state without recording a timing. Used when a probe succeeds
    /// but nothing was spoken, e.g. the voice list loaded at launch.
    mutating func markReachable() {
        unreachableReason = nil
    }

    // MARK: - Reading

    /// Number of measurements currently in the window.
    var sampleCount: Int { samples.count }

    /// Median of the window, or nil when nothing has been measured.
    ///
    /// Even counts average the two middle values, which is the standard definition and
    /// keeps the number from jumping between two neighbouring samples as the window
    /// slides.
    var median: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    var status: Status {
        if let reason = unreachableReason {
            return .unreachable(reason: reason)
        }
        guard let median else { return .unknown }
        return median > slowThreshold ? .slow(median: median) : .healthy(median: median)
    }

    /// One line for the menu. Plain words, no jargon, and where there is something the
    /// user can actually do, it says what.
    ///
    /// Note what it does *not* say: nothing here offers to restart the engine, because
    /// this app cannot. Suggesting an action the UI can't perform would be worse than
    /// the silence it replaces.
    var summary: String {
        switch status {
        case .unknown:
            return "Voice engine: not measured yet"
        case .unreachable(let reason):
            return "Voice engine is unreachable — \(reason)"
        case .healthy(let median):
            return "Voice engine is responsive (\(Self.format(median)))"
        case .slow(let median):
            return "Voice engine is slow (\(Self.format(median))) — restarting it may help"
        }
    }

    /// One decimal place and an explicit unit. `1.0s`, not `1.0000000001`.
    static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }
}
