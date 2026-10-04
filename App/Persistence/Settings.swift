import Foundation
import Security

/// UserDefaults keys. Views use `@AppStorage` with these; non-view code reads `UserDefaults.standard`.
enum SettingsKey {
    static let onboardingDone = "onboardingDone"
    static let kanjiIntensity = "kanjiIntensity"
    static let showRomaji = "showRomaji"
    static let showEnglish = "showEnglish"
    /// A voice identifier, or empty for the most natural installed voice. (Older builds stored an accent: "en-IN".)
    static let englishVoice = "englishVoice"
    /// A voice identifier, or empty for the most natural installed Japanese voice.
    static let japaneseVoice = "japaneseVoice"
    static let coachServerURL = "coachServerURL"
    static let lastMinutes = "lastMinutes"
    static let lastFocus = "lastFocus"
    /// The hands-free help words (もう一度, ゆっくり, ヒント, 答え) have been taught.
    static let helpOnboardingDone = "helpOnboardingDone"
    /// When the learner last saved a backup file (seconds since 1970; 0 = never).
    static let lastBackupAt = "lastBackupAt"
}

/// How much kanji to show (spec §41). Default: minimal.
enum KanjiIntensity: String, CaseIterable, Identifiable {
    /// Kana only.
    case off
    /// Kana first, kanji as a small secondary line.
    case minimal
    /// Kanji first, kana reading underneath.
    case normal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .normal: "Normal"
        }
    }
}

/// The coach-server token lives in the Keychain, never in UserDefaults.
enum CoachTokenStore {
    private static let service = "com.swapnil.hanaseru.coach-token"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func save(_ token: String) {
        delete()
        guard !token.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}
