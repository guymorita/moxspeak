import Foundation

/// Append-only diagnostic log at `~/Library/Logs/Speakeasy.log`.
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

    private static let fileURL: URL? = {
        guard let logs = try? FileManager.default.url(for: .libraryDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: false) else { return nil }
        return logs.appending(path: "Logs/Speakeasy.log")
    }()

    /// Truncate above this so an app left running for weeks cannot fill a disk.
    private static let maximumBytes = 512 * 1024

    private static let lock = NSLock()

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
