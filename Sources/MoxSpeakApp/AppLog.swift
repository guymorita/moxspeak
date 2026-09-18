import Foundation

/// Append-only diagnostic log at `~/Library/Logs/MoxSpeak.log`.
///
/// An `LSUIElement` app launched by LaunchServices has no terminal attached: stderr goes
/// nowhere a person can see it. Without a file, every startup problem — a hotkey another
/// app already owns, an audio device that refused to start — is invisible to anyone
/// trying to work out why nothing happened. The UI still says everything a *user* needs;
/// this is for the case where the UI itself didn't come up.
///
/// Deliberately not a framework. No levels, no rotation beyond a size cap, no
/// dependencies.
enum AppLog {

    /// Where the log is. Readable so `Reset` deletes exactly the file this writes rather
    /// than a path spelled out a second time somewhere else — two copies of a path is how
    /// an "uninstall" ends up leaving the log behind.
    static let fileURL: URL? = {
        guard let logs = try? FileManager.default.url(for: .libraryDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: false) else { return nil }
        return logs.appending(path: "Logs/MoxSpeak.log")
    }()

    /// Truncate above this so an app left running for weeks cannot fill a disk.
    private static let maximumBytes = 512 * 1024

    private static let lock = NSLock()

    /// Set by `stopLogging()` and never cleared: a reset is a one-way door for the rest
    /// of the process.
    ///
    /// Without this, "delete the log" would be a lie by the time the user got to the
    /// Trash — `applicationWillTerminate` writes `terminate`, which recreates the file on
    /// the way out and leaves a one-line log behind on a machine the user believes is
    /// clean. Guarded by the same lock as `write`, so a line already on its way cannot
    /// slip in after the file has gone.
    ///
    /// `nonisolated(unsafe)` is load-bearing rather than a silenced diagnostic: every
    /// read and every write below happens inside `lock`, which is the external
    /// synchronisation the compiler is asking after. (Contrast `SelectionReader`, which
    /// refuses the same annotation — there it would have been covering an SDK global that
    /// nothing synchronises at all.)
    nonisolated(unsafe) private static var isStopped = false

    /// Stops writing for the remainder of this launch. The next launch logs normally —
    /// this suppresses the log of an app being uninstalled, not logging as a feature.
    static func stopLogging() {
        lock.lock()
        defer { lock.unlock() }
        isStopped = true
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        guard let fileURL else { return }
        let line = "\(timestamp.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }

        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }

        if let size = try? handle.seekToEnd(), size > UInt64(maximumBytes) {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: data)
    }
}
