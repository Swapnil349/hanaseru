import ConversationCore
import LearningCore
import SwiftData
import SwiftUI

@main
struct HanaseruApp: App {
    @State private var environment: AppEnvironment

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: LearnerProfileRecord.self, KnowledgeRecord.self, MistakeRecord.self,
                SessionRecord.self, PersonalPhraseRecord.self
            )
        } catch {
            fatalError("Could not open the learning database: \(error)")
        }
        _environment = State(initialValue: AppEnvironment(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Palette.line)
        }
        .modelContainer(environment.container)
    }
}

/// App-wide dependencies. Created once; injected into views with `.environment`.
@Observable
@MainActor
final class AppEnvironment {
    let container: ModelContainer
    let library: ContentLibrary
    let contentError: String?
    let repository: SwiftDataLearnerRepository
    let voice = VoiceEngine()

    init(container: ModelContainer) {
        self.container = container
        do {
            library = try ContentLibrary.bundled()
            contentError = nil
        } catch {
            library = ContentLibrary(items: [])
            contentError = String(describing: error)
        }
        repository = SwiftDataLearnerRepository(context: container.mainContext)
    }

    /// Claude via the coach proxy when configured, always backed by the offline engine (spec §59).
    func makeAIProvider() -> AIProvider {
        let offline = OfflineAIProvider(library: library)
        guard let remote = makeRemoteProvider() else { return offline }
        return ResilientAIProvider(primary: remote, fallback: offline)
    }

    func makeRemoteProvider() -> RemoteAIProvider? {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.coachServerURL) ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true,
              let token = CoachTokenStore.read() else { return nil }
        return RemoteAIProvider(baseURL: url, token: token)
    }

    var isCoachConfigured: Bool { makeRemoteProvider() != nil }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Practice", systemImage: "waveform") }
            MyJapaneseView()
                .tabItem { Label("My Japanese", systemImage: "text.book.closed") }
            ProgressDashboardView()
                .tabItem { Label("Progress", systemImage: "chart.bar.xaxis") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboardingDone }, set: { _ in })) {
            OnboardingView()
        }
    }
}
