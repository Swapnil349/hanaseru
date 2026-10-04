import AVFoundation
import ConversationCore
import SessionCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Query private var profiles: [LearnerProfileRecord]

    @AppStorage(SettingsKey.kanjiIntensity) private var kanjiIntensity = KanjiIntensity.minimal.rawValue
    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false
    @AppStorage(SettingsKey.showEnglish) private var showEnglish = true
    @AppStorage(SettingsKey.englishVoice) private var englishVoice = ""
    @AppStorage(SettingsKey.japaneseVoice) private var japaneseVoice = ""
    @State private var logFile: URL?
    @AppStorage(SettingsKey.coachServerURL) private var coachServerURL = ""
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = true
    @AppStorage(SettingsKey.lastBackupAt) private var lastBackupAt = 0.0

    @State private var name = ""
    @State private var token = ""
    @State private var connectionStatus: String?
    @State private var confirmVoiceDelete = false
    @State private var confirmReset = false
    @State private var backupDocument: BackupDocument?
    @State private var backupFileName = ""
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var pendingRestore: LearnerBackup?
    @State private var backupStatus: String?

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
                    voicePicker("English voice", selection: $englishVoice, language: .english,
                                sample: "Say: No, there's no particular problem.")
                    voicePicker("Japanese voice", selection: $japaneseVoice, language: .japanese,
                                sample: "いいえ、特に問題はありません。")
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Basic voices sound robotic. For natural speech, download voices marked Enhanced or Premium in the iPhone's Settings › Accessibility › Spoken Content (Read & Speak) › Voices — under English (any accent) and Japanese. Hanaseru then uses the best one automatically.")
                }

                Section {
                    if let logFile {
                        ShareLink(item: logFile) { Label("Send the voice log", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("Prepare the voice log") { logFile = VoiceLog.shared.exportFile() }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("If a session goes quiet, this log shows what the voice engine was doing. It contains timings and the coach's words, never what you said.")
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
                    if let expiry = InstallInfo.expiryText {
                        LabeledContent("This install works until", value: expiry)
                    }
                    Button("Back up my progress…") { prepareBackup() }
                        .fileExporter(isPresented: $showBackupExporter, document: backupDocument, contentType: .json,
                                      defaultFilename: backupFileName) { result in
                            switch result {
                            case .success(let url):
                                lastBackupAt = Date().timeIntervalSince1970
                                backupStatus = "Saved “\(url.lastPathComponent)”."
                            case .failure(let error):
                                backupStatus = "Not saved: \(error.localizedDescription)"
                            }
                        }
                    Button("Restore from a backup…") { showBackupImporter = true }
                        .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.json]) { result in
                            readBackup(result)
                        }
                    if let backupStatus {
                        Text(backupStatus).font(.footnote).foregroundStyle(Palette.inkSecondary)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text(backupFooter)
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
                // Older builds stored an accent ("en-IN") rather than a voice: switch to the best installed voice.
                if englishVoice.hasPrefix("en-") && englishVoice.count <= 6 { englishVoice = "" }
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
            .confirmationDialog("Replace your progress on this iPhone with this backup?",
                                isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                                titleVisibility: .visible, presenting: pendingRestore) { backup in
                Button("Restore", role: .destructive) { restore(backup) }
            } message: { backup in
                Text(backup.overview)
            }
        }
    }

    // MARK: - Backup

    private var backupFooter: String {
        let last = lastBackupAt > 0
            ? "Last backup: " + Date(timeIntervalSince1970: lastBackupAt).formatted(date: .abbreviated, time: .shortened) + ". "
            : "No backup yet. "
        return last + "Save the file to iCloud Drive or Files. Reinstalling with the same Apple ID keeps your progress; "
            + "with a different Apple ID the app starts empty, and this file brings everything back."
    }

    private func prepareBackup() {
        do {
            let backup = app.repository.makeBackup()
            backupDocument = BackupDocument(data: try backup.encoded())
            backupFileName = LearnerBackup.fileName(for: backup.exportedAt)
            showBackupExporter = true
        } catch {
            backupStatus = "Couldn't make the backup: \(error.localizedDescription)"
        }
    }

    private func readBackup(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingRestore = try LearnerBackup.decode(Data(contentsOf: url))
            } catch {
                backupStatus = error.localizedDescription
            }
        case .failure(let error):
            backupStatus = error.localizedDescription
        }
    }

    private func restore(_ backup: LearnerBackup) {
        app.repository.restore(backup)
        name = backup.profile.name
        pendingRestore = nil
        backupStatus = "Restored: \(backup.overview)."
    }

    /// A list of installed voices, best first, with "Best installed" as the default and a preview button.
    @ViewBuilder
    private func voicePicker(_ title: String, selection: Binding<String>, language: SpeechLanguage, sample: String) -> some View {
        let voices = AppleSpeechSynthesisProvider.candidates(for: language)
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
        let best = AppleSpeechSynthesisProvider.bestVoice(for: language)
        Picker(title, selection: selection) {
            Text("Best installed" + (best.map { " (\($0.name), \(AppleSpeechSynthesisProvider.qualityName($0)))" } ?? ""))
                .tag("")
            ForEach(voices, id: \.identifier) { voice in
                Text("\(voice.name) — \(accentName(voice.language)) · \(AppleSpeechSynthesisProvider.qualityName(voice))")
                    .tag(voice.identifier)
            }
        }
        .onChange(of: selection.wrappedValue) { AppleSpeechSynthesisProvider.resetVoiceCache() }
        Button {
            VoicePreview.shared.play(sample, voice: AppleSpeechSynthesisProvider.voice(for: language))
        } label: {
            Label("Hear the \(language == .japanese ? "Japanese" : "English") voice", systemImage: "play.circle")
        }
    }

    private func accentName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
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
