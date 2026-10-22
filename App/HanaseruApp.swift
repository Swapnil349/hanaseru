import ConversationCore
import LearningCore
import SessionCore
import SwiftData
import SwiftUI

@main
struct HanaseruApp: App {
    @State private var environment: AppEnvironment

    init() {
        // Any freeze is written to the voice log (Settings › Diagnostics), which survives a forced quit.
        HangDetector.shared.start()
        VoiceLog.add("app started")
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
    /// The bundled content with the learner's own scenes in it: what every screen and session uses.
    private(set) var library: ContentLibrary
    let contentError: String?
    let repository: SwiftDataLearnerRepository
    let voice = VoiceEngine()
    /// The learner's own scenes (My scenes).
    let myScenes = MySceneStore()
    /// Listen: scenes played back to back, hands-free (docs/LISTEN.md).
    let listen = ListenPlayer()
    /// The practice session running, if any. Listen ends it before playing: the two never share the audio.
    @ObservationIgnored weak var activeSession: SessionViewModel?
    private let bundledLibrary: ContentLibrary

    init(container: ModelContainer) {
        self.container = container
        let bundled: ContentLibrary
        do {
            bundled = try ContentLibrary.bundled()
            contentError = nil
        } catch {
            bundled = ContentLibrary(items: [])
            contentError = String(describing: error)
        }
        bundledLibrary = bundled
        library = bundled
        repository = SwiftDataLearnerRepository(context: container.mainContext)
        refreshLibrary()
        myScenes.onChange = { [weak self] in self?.refreshLibrary() }
    }

    /// Puts the learner's own scenes into the library (after a change, or when their name changed).
    func refreshLibrary() {
        let name = (try? container.mainContext.fetch(FetchDescriptor<LearnerProfileRecord>()))?.first?.name ?? ""
        library = bundledLibrary.including(myScenes.scenes, learnerName: name)
    }

    /// Plays a Listen playlist, ending a practice session first.
    func startListening(_ playlist: ListenPlaylist) {
        if let activeSession {
            VoiceLog.add("practice session ended for Listen")
            activeSession.teardown()
            self.activeSession = nil
        }
        listen.play(playlist)
    }

    /// Claude via the coach proxy when configured, always backed by the offline engine (spec §59).
    func makeAIProvider() -> AIProvider {
        let offline = OfflineAIProvider(library: library)
        guard let remote = makeRemoteProvider() else { return offline }
        return ResilientAIProvider(primary: remote, fallback: offline)
    }

    func makeRemoteProvider(timeout: TimeInterval = 12) -> RemoteAIProvider? {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.coachServerURL) ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true,
              let token = CoachTokenStore.read() else { return nil }
        return RemoteAIProvider(baseURL: url, token: token, timeout: timeout)
    }

    private var lastWake: Date?

    /// A free host puts the coach server to sleep after 15 idle minutes and takes up to a minute to wake it.
    /// Knock early (app opened, session or translation starting) so it's awake by the time it's needed.
    func wakeCoach() {
        guard let remote = makeRemoteProvider() else { return }
        if let lastWake, Date().timeIntervalSince(lastWake) < 300 { return }
        lastWake = Date()
        Task { try? await remote.checkHealth(timeout: 75) }
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
            WritingPracticeView()
                .tabItem { Label("Write", systemImage: "pencil.and.scribble") }
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
