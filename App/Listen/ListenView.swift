import LearningCore
import SessionCore
import SwiftData
import SwiftUI

/// Listen (docs/LISTEN.md): short scenes played back to back for driving or chores. Choose once, press Play, put the
/// phone away. Nothing is asked; the screen only shows what is playing. Leaving the screen keeps it playing.
struct ListenView: View {
    @Environment(AppEnvironment.self) private var app
    @Query private var profiles: [LearnerProfileRecord]

    @AppStorage(SettingsKey.listenLanguage) private var languageRaw = ListenLanguage.japaneseOnly.rawValue
    @AppStorage(SettingsKey.listenLength) private var lengthRaw = ListenLength.five.rawValue
    @AppStorage(SettingsKey.listenSource) private var sourceRaw = ListenSource.myWork.rawValue
    @AppStorage(SettingsKey.listenSpeed) private var speedRaw = ListenSpeed.natural.rawValue
    @AppStorage(SettingsKey.workField) private var workFieldRaw = WorkField.engineering.rawValue
    @AppStorage(SettingsKey.showEnglish) private var showEnglish = true
    @State private var problem: String?

    private var language: ListenLanguage { ListenLanguage(rawValue: languageRaw) ?? .japaneseOnly }
    private var length: ListenLength { ListenLength(rawValue: lengthRaw) ?? .five }
    private var source: ListenSource { ListenSource(rawValue: sourceRaw) ?? .myWork }
    private var speed: ListenSpeed { ListenSpeed(rawValue: speedRaw) ?? .natural }
    private var field: WorkField { WorkField(rawValue: workFieldRaw) ?? .engineering }

    var body: some View {
        let player = app.listen
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if player.state != .idle, let playlist = player.playlist {
                    nowPlaying(playlist)
                } else {
                    choices
                }
            }
            .padding(Metrics.padding)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .navigationTitle("Listen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.refreshLibrary() }
    }

    // MARK: - Choosing

    private var choices: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                LineStripe().frame(width: 36)
                Text("聞くだけ").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                Text("Listen while driving")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text("Short scenes, one after another, like a radio drama. Nothing to say and nothing to tap.")
                    .font(.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
            chooser(ja: "言葉", en: "Language", options: ListenLanguage.allCases, selection: language,
                    label: { ($0.title, nil) }) { languageRaw = $0.rawValue }
            chooser(ja: "長さ", en: "Length", options: ListenLength.allCases, selection: length,
                    label: { ("\($0.minutes)", "min") }) { lengthRaw = $0.rawValue }
            VStack(alignment: .leading, spacing: 8) {
                chooser(ja: "場面", en: "Scenes from", options: ListenSource.allCases, selection: source,
                        label: { ($0.title, nil) }) { sourceRaw = $0.rawValue }
                if ListenPlaylist.scenarios(in: app.library, field: field, source: source).isEmpty {
                    Text("No scenes there yet, so Listen plays from Everything.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            chooser(ja: "速さ", en: "Speed", options: ListenSpeed.allCases, selection: speed,
                    label: { ($0.title, nil) }) { speedRaw = $0.rawValue }
            PrimaryButton(title: "Play", systemImage: "play.fill") { play() }
                .accessibilityIdentifier("listen-play")
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.caution)
            }
            Text("Keeps playing with the screen locked. Your headphones' or car's buttons pause it and skip scenes.")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .padding(.top, -16)
        }
    }

    /// A row of choices under a bilingual label.
    private func chooser<Option: Hashable>(ja: String, en: String, options: [Option], selection: Option,
                                           label: @escaping (Option) -> (String, String?),
                                           choose: @escaping (Option) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ja: ja, en: en)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        let text = label(option)
                        ChoiceChip(title: text.0, subtitle: text.1, isSelected: option == selection) { choose(option) }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func play() {
        let choices = ListenPlaylist.Choices(language: language, length: length, source: source, speed: speed)
        let playlist = ListenPlaylist.make(library: app.library, field: field, choices: choices,
                                           learnerName: profiles.first?.name ?? "", recentlyPlayed: ListenHistory.recent)
        guard !playlist.isEmpty else {
            problem = "There are no scenes to play yet."
            return
        }
        problem = nil
        app.startListening(playlist)
    }

    // MARK: - Playing

    @ViewBuilder
    private func nowPlaying(_ playlist: ListenPlaylist) -> some View {
        let player = app.listen
        let finished = player.state == .finished
        VStack(alignment: .leading, spacing: 6) {
            LineStripe().frame(width: 36)
            Text(status(of: player, in: playlist))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityIdentifier("listen-status")
            Text(finished ? "Well done" : (player.scene?.title ?? "The end"))
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Palette.ink)
            if !finished, let titleJa = player.scene?.titleJa, !titleJa.isEmpty {
                Text(titleJa)
                    .font(.headline)
                    .foregroundStyle(Palette.inkSecondary)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
            }
            if playlist.source != playlist.choices.source {
                Text("No scenes in \(playlist.choices.source.title) yet, so these are from Everything.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }

        if !finished {
            PracticeCard {
                if let line = player.current, !line.japanese.isEmpty {
                    if !line.speaker.isEmpty {
                        Text(line.speaker).font(.caption.weight(.semibold)).foregroundStyle(Palette.line)
                    }
                    JapaneseTextView(japanese: line.japanese, kana: line.kana, english: line.english, style: .title,
                                     showEnglish: showEnglish || playlist.choices.language == .withEnglish)
                } else {
                    Text(player.state == .paused ? "Paused" : "…")
                        .font(.title3)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .frame(minHeight: 160, alignment: .top)

            controls(player, playlist: playlist)

            Button {
                player.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("listen-stop")
            Text("Leaving this screen keeps it playing. Scenes heard here aren't marked as practised.")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .padding(.top, -16)
        } else {
            PrimaryButton(title: "Play more scenes", systemImage: "play.fill") { play() }
                .accessibilityIdentifier("listen-again")
            Button {
                player.stop(reason: "change choices")
            } label: {
                Label("Change the choices", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// "Scene 2 of 6", "Scene 2 of 6 · Paused", "Starting…", "Finished · 6 scenes".
    private func status(of player: ListenPlayer, in playlist: ListenPlaylist) -> String {
        let count = playlist.scenes.count
        let place = player.sceneIndex < count ? "Scene \(player.sceneIndex + 1) of \(count)" : "The end"
        return switch player.state {
        case .starting: "\(place) · Starting…"
        case .paused: "\(place) · Paused"
        case .finished: "Finished · \(count) scene\(count == 1 ? "" : "s")"
        case .playing, .idle: place
        }
    }

    /// Previous scene, Play/Pause, Next scene: big enough to hit without looking for long.
    private func controls(_ player: ListenPlayer, playlist: ListenPlaylist) -> some View {
        HStack(spacing: 28) {
            roundButton("backward.end.fill", label: "Previous scene", size: 72) { player.previousScene() }
                .accessibilityIdentifier("listen-previous")
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 104)
                    .background(Palette.line, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("listen-play-pause")
            roundButton("forward.end.fill", label: "Next scene", size: 72) { player.nextScene() }
                .disabled(player.sceneIndex >= playlist.scenes.count)
                .accessibilityIdentifier("listen-next")
        }
        .frame(maxWidth: .infinity)
    }

    private func roundButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: size, height: size)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
