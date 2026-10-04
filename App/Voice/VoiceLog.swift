import Foundation

/// A small diagnostic log of what the voice engine did (speech, listening, pauses, audio-route changes),
/// so a session that went quiet can be explained afterwards. It never contains the learner's words or
/// audio, only timings and what the coach said. Shared from Settings › Diagnostics.
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

    static func add(_ message: String) {
        shared.append(message)
    }

    private func append(_ message: String) {
        lock.withLock {
            lines.append("\(formatter.string(from: Date()))  \(message)")
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }

    /// Writes the log to a file and returns it, ready to share.
    func exportFile() -> URL? {
        let text = lock.withLock { lines.joined(separator: "\n") }
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
