import Foundation

/// The rules that keep a session from going quiet (spec §61). An utterance that never starts, or that
/// "finishes" far sooner than its words take to say, made no sound: the voice engine brings the audio back
/// and says it once more, then gives up and lets the session carry on. Whatever a voice does, the session
/// never waits on it past a deadline. Pure, so the decisions can be tested without audio.
public enum SpeechGuard {
    /// What happened to one utterance.
    public enum Verdict: Equatable, Sendable {
        case spoken
        /// No start was reported in time.
        case neverStarted
        /// It "finished" too soon to have been heard (audio session inactive, interrupted, route changing).
        case tooFast
    }

    /// What the voice does after an utterance.
    public enum NextStep: Equatable, Sendable {
        case done
        /// Bring the audio session and engine back, then say it once more.
        case recoverAndRetry
        /// Tried twice without sound: log it and let the session carry on.
        case giveUp
    }

    /// An utterance that hasn't started by then is treated as lost. (A Premium voice's very first sentence can
    /// take a moment to load; the retry then starts at once.)
    public static let startTimeout: TimeInterval = 2.5
    /// A new synthesizer (after a pause, a stop or a recovery) loads its voice before its first sentence; a
    /// Premium voice can take several seconds, and that is not silence.
    public static let firstStartTimeout: TimeInterval = 7
    /// Shorter text is too short to judge by its length: 「はい」 really is over in a moment.
    public static let minimumCharacters = 6
    /// Finished in less than this share of its expected time: nothing was heard.
    public static let tooFastShare = 0.25
    /// After this many lines in a row that ended without sound (not merely slow to start), the session pauses
    /// rather than carry on in silence.
    public static let silentLinesBeforePause = 3

    /// A cautious (short) estimate of how long the text takes to say, without the pause after it.
    public static func expectedSpeakingTime(of request: SpeechRequest) -> TimeInterval {
        let charactersPerSecond = request.language == .japanese ? 6.0 : 12.0
        let characters = request.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return Double(characters) / charactersPerSecond / max(request.rate, 0.5)
    }

    /// How an utterance that reported its end went, from how long it took.
    public static func verdict(for request: SpeechRequest, elapsed: TimeInterval) -> Verdict {
        let characters = request.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard characters >= minimumCharacters else { return .spoken }
        return elapsed < expectedSpeakingTime(of: request) * tooFastShare ? .tooFast : .spoken
    }

    /// `attempt` counts from 1. One retry after recovering the audio, never more.
    public static func nextStep(after verdict: Verdict, attempt: Int) -> NextStep {
        guard verdict != .spoken else { return .done }
        return attempt < 2 ? .recoverAndRetry : .giveUp
    }

    /// The longest the session waits for one utterance, whatever the voice does: two tries, each allowed to
    /// start late and run long, and the audio recovery between them.
    public static func deadline(for request: SpeechRequest) -> TimeInterval {
        2 * firstStartTimeout + 3 * expectedSpeakingTime(of: request) + request.pauseAfter + 10
    }

    /// The longest the session waits for one listen. Written answers can take up to 90 s.
    public static func listenDeadline(for options: ListenOptions) -> TimeInterval {
        max(options.startTimeout, 90) + options.maxDuration + 10
    }
}
