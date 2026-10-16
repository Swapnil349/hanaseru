import Foundation

/// A small diagnostic log of what the voice engine did (speech, listening, pauses, audio-route changes),
/// so a session that went quiet — or froze — can be explained afterwards. It never contains the learner's
/// words or audio, only timings and what the coach said. Shared from Settings › Diagnostics.
///
/// Every line is also written to a file as it happens, and the last run's file is kept, so even after a
/// freeze and a forced quit the log shows what happened just before.
final class VoiceLog: @unchecked Sendable {
    static let shared = VoiceLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 800
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    private let queue = DispatchQueue(label: "hanaseru.voice-log", qos: .utility)
    private let fileURL: URL
    private let previousURL: URL
    private var handle: FileHandle?

    private init() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = folder.appendingPathComponent("voice-log.txt")
        previousURL = folder.appendingPathComponent("voice-log-previous.txt")
        let files = FileManager.default
        try? files.removeItem(at: previousURL)
        try? files.moveItem(at: fileURL, to: previousURL)
        files.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    static func add(_ message: String) {
        shared.append(message)
    }

    private func append(_ message: String) {
        let line = lock.withLock { () -> String in
            let line = "\(formatter.string(from: Date()))  \(message)"
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            return line
        }
        queue.async { [weak self] in
            try? self?.handle?.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Writes the log (the last run's and this one's) to a file and returns it, ready to share.
    func exportFile() -> URL? {
        let previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        let current = lock.withLock { lines.joined(separator: "\n") }
        var text = ""
        if !previous.isEmpty { text += "— The previous time the app ran —\n" + previous + "\n\n" }
        text += "— This time —\n" + current
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Hanaseru voice log.txt")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    var isEmpty: Bool { lock.withLock { lines.isEmpty } }
}

/// Notices when the screen stops responding (the main thread is blocked) and writes it to the voice log,
/// which survives a forced quit, so a freeze can be traced afterwards.
final class HangDetector: @unchecked Sendable {
    static let shared = HangDetector()

    private let queue = DispatchQueue(label: "hanaseru.hang-detector", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastPong = Date()
    private var lastTick = Date()
    private var stalledSince: Date?

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func tick() {
        let now = Date()
        DispatchQueue.main.async { [weak self] in self?.pong() }
        lock.withLock {
            // After the app was suspended in the background, start counting afresh.
            if now.timeIntervalSince(lastTick) > 2 { lastPong = now }
            lastTick = now
            let silent = now.timeIntervalSince(lastPong)
            if silent > 2 && stalledSince == nil {
                stalledSince = lastPong
                VoiceLog.add("WARNING: the screen stopped responding (main thread blocked)")
            }
        }
    }

    private func pong() {
        let now = Date()
        lock.withLock {
            if let since = stalledSince {
                VoiceLog.add(String(format: "the screen responds again after %.1f s", now.timeIntervalSince(since)))
            }
            stalledSince = nil
            lastPong = now
        }
    }
}
