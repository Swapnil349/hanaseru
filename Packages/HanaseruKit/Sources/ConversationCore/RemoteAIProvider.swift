import Foundation
import LearningCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Hanaseru coach proxy (backend/). The proxy holds the Anthropic API key; the app only
/// holds a per-user token for the proxy (spec §54: no secret keys in the app).
public struct RemoteAIProvider: AIProvider {
    public let name = "Claude"
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL, token: String, session: URLSession = .shared, timeout: TimeInterval = 12) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.timeout = timeout
    }

    public func generateResponse(_ request: TurnRequest) async throws -> TurnResponse {
        try await post("v1/turn", body: request)
    }

    public func evaluateResponse(_ request: EvaluationRequest) async throws -> TurnEvaluation {
        try await post("v1/evaluate", body: request)
    }

    /// English into the Japanese a Japanese colleague would actually say (not word for word).
    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await post("v1/translate", body: request)
    }

    /// Cheap reachability + auth check for the settings screen.
    public func checkHealth() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await data(for: request)
        try Self.validate(response, data: Data())
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await data(for: request)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIProviderError.badResponse("Could not decode \(Response.self): \(error)")
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIProviderError.transport(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.transport("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.transport("HTTP \(http.statusCode) \(message.prefix(200))")
        }
    }
}

/// Tries the primary provider within a latency budget and falls back on any failure (spec §59).
/// Hands-free use can't tolerate a long silence, so the budget is short.
public final class ResilientAIProvider: AIProvider, @unchecked Sendable {
    public let primary: AIProvider
    public let fallback: AIProvider
    public let timeout: TimeInterval
    private let lock = NSLock()
    private var _lastFailure: AIProviderError?

    public var name: String { primary.name }

    /// The last error from the primary provider, cleared on the next success. Lets the UI say "offline mode".
    public var lastFailure: AIProviderError? {
        lock.lock(); defer { lock.unlock() }
        return _lastFailure
    }

    public init(primary: AIProvider, fallback: AIProvider, timeout: TimeInterval = 8) {
        self.primary = primary
        self.fallback = fallback
        self.timeout = timeout
    }

    public func generateResponse(_ request: TurnRequest) async throws -> TurnResponse {
        try await attempt({ try await self.primary.generateResponse(request) },
                          otherwise: { try await self.fallback.generateResponse(request) })
    }

    public func evaluateResponse(_ request: EvaluationRequest) async throws -> TurnEvaluation {
        try await attempt({ try await self.primary.evaluateResponse(request) },
                          otherwise: { try await self.fallback.evaluateResponse(request) })
    }

    private func attempt<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T,
                                      otherwise backup: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            let value = try await withTimeout(timeout, operation)
            record(nil)
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIProviderError {
            record(error)
            return try await backup()
        } catch {
            record(.transport(error.localizedDescription))
            return try await backup()
        }
    }

    private func record(_ failure: AIProviderError?) {
        lock.lock(); defer { lock.unlock() }
        _lastFailure = failure
    }
}

/// Runs `operation`, throwing `AIProviderError.timedOut` if it takes longer than `seconds`.
public func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AIProviderError.timedOut
        }
        guard let first = try await group.next() else { throw AIProviderError.timedOut }
        group.cancelAll()
        return first
    }
}

/// What the learner wants to say, and how politely (see backend /v1/translate).
public struct TranslationRequest: Codable, Equatable, Sendable {
    public var english: String
    public var politeness: Politeness
    /// Optional: who it's said to and where, e.g. "to my senior engineer at the site".
    public var situation: String?

    public init(english: String, politeness: Politeness, situation: String? = nil) {
        self.english = english
        self.politeness = politeness
        self.situation = situation
    }
}

public struct TranslationResult: Codable, Equatable, Sendable {
    public struct Alternative: Codable, Equatable, Sendable {
        public var japanese: String
        public var kana: String
        public var whenToUse: String
    }

    public var japanese: String
    public var kana: String
    /// What the Japanese literally says, back in English.
    public var backTranslation: String
    public var notes: String
    public var alternatives: [Alternative]

    public init(japanese: String, kana: String, backTranslation: String = "", notes: String = "",
                alternatives: [Alternative] = []) {
        self.japanese = japanese
        self.kana = kana
        self.backTranslation = backTranslation
        self.notes = notes
        self.alternatives = alternatives
    }
}
