import ConversationCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Query private var profiles: [LearnerProfileRecord]

    @AppStorage(SettingsKey.kanjiIntensity) private var kanjiIntensity = KanjiIntensity.minimal.rawValue
    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false
    @AppStorage(SettingsKey.showEnglish) private var showEnglish = true
    @AppStorage(SettingsKey.englishVoice) private var englishVoice = "en-IN"
    @AppStorage(SettingsKey.coachServerURL) private var coachServerURL = ""
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = true

    @State private var name = ""
    @State private var token = ""
    @State private var connectionStatus: String?
    @State private var confirmVoiceDelete = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Your name", text: $name)
                        .onSubmit { app.repository.setName(name) }
                }

                Section {
                    Picker("Kanji", selection: $kanjiIntensity) {
                        ForEach(KanjiIntensity.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Show romaji", isOn: $showRomaji)
                    Toggle("Show English on screen", isOn: $showEnglish)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Minimal shows kana first with kanji as a small hint. Kanji is never the focus.")
                }

                Section {
                    Picker("English voice", selection: $englishVoice) {
                        Text("Indian English").tag("en-IN")
                        Text("US English").tag("en-US")
                        Text("British English").tag("en-GB")
                    }
                    .onChange(of: englishVoice) { AppleSpeechSynthesisProvider.resetVoiceCache() }
                    LabeledContent("Japanese voice quality", value: AppleSpeechSynthesisProvider.japaneseVoiceQuality)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("For a more natural Japanese voice, download “Japanese – Premium” in iOS Settings › Accessibility › Spoken Content › Voices.")
                }

                Section {
                    TextField("https://your-coach-server.example", text: $coachServerURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access token", text: $token)
                        .onSubmit { CoachTokenStore.save(token) }
                    Button("Save and test connection") { Task { await testConnection() } }
                    if let connectionStatus {
                        Text(connectionStatus).font(.footnote).foregroundStyle(Palette.inkSecondary)
                    }
                } header: {
                    Text("AI coach")
                } footer: {
                    Text("Optional. With a coach server, conversations adapt to what you say. Without one, sessions use built-in scenarios and work fully offline. The app never holds an Anthropic API key — only a token for your own server.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        privacyRow("mic", "The microphone is only transcribed during your turn. The indicator on screen shows when.")
                        privacyRow("iphone", app.voice.recognizer.processingDescription + ".")
                        privacyRow("waveform.slash", "Audio is never recorded or saved.")
                        privacyRow("text.quote", "Only the text of mistakes is kept, to help you practise them.")
                        privacyRow("server.rack", "With an AI coach, the text of your answers (never audio) is sent to your coach server and Anthropic.")
                    }
                    .padding(.vertical, 4)
                    Button("Delete voice data", role: .destructive) { confirmVoiceDelete = true }
                    Button("Reset all learning data", role: .destructive) { confirmReset = true }
                } header: {
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                name = profiles.first?.name ?? ""
                token = CoachTokenStore.read() ?? ""
            }
            .confirmationDialog("Delete the stored text of everything you've said?", isPresented: $confirmVoiceDelete, titleVisibility: .visible) {
                Button("Delete voice data", role: .destructive) { app.repository.deleteVoiceData() }
            }
            .confirmationDialog("Delete all progress, phrases and mistakes? This can't be undone.", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) {
                    app.repository.deleteEverything()
                    onboardingDone = false
                }
            }
        }
    }

    private func privacyRow(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.footnote) } icon: { Image(systemName: symbol).foregroundStyle(Palette.line) }
    }

    private func testConnection() async {
        CoachTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let provider = app.makeRemoteProvider() else {
            connectionStatus = "Enter a server URL (https://…) and a token."
            return
        }
        connectionStatus = "Testing…"
        do {
            try await provider.checkHealth()
            connectionStatus = "Connected. Conversations will use the AI coach."
        } catch {
            connectionStatus = "Couldn't connect: \(error)"
        }
    }
}
