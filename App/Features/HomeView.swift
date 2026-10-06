import LearningCore
import SwiftData
import SwiftUI

/// "What Japanese would be most useful right now?" (spec §48, §68)
struct HomeView: View {
    @Environment(AppEnvironment.self) private var app
    @Query private var profiles: [LearnerProfileRecord]
    @Query(sort: \PersonalPhraseRecord.createdAt, order: .reverse) private var phrases: [PersonalPhraseRecord]
    @Query(sort: \MistakeRecord.occurrences, order: .reverse) private var mistakes: [MistakeRecord]

    @AppStorage(SettingsKey.lastMinutes) private var minutes = 5
    @AppStorage(SettingsKey.lastFocus) private var focusRaw = SessionFocus.surprise.rawValue
    @State private var activeSession: SessionRequest?
    @State private var showCapture = false
    @AppStorage("voiceTipDismissed") private var voiceTipDismissed = false

    private let timeOptions = [2, 5, 10, 20, 30]
    private var focus: SessionFocus { SessionFocus(rawValue: focusRaw) ?? .surprise }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greeting
                    expiryBanner
                    voiceTip
                    timePicker
                    focusPicker
                    PrimaryButton(title: "Start \(minutes)-minute session", systemImage: "headphones") {
                        activeSession = SessionRequest(minutes: minutes, focus: focus)
                    }
                    .accessibilityIdentifier("start-session")
                    Text("Put your earphones in and your phone away — everything is spoken.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .padding(.top, -16)

                    scenesCard
                    heardThisCard
                    myJapaneseCard
                }
                .padding(Metrics.padding)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { app.wakeCoach() }
        .fullScreenCover(item: $activeSession) { request in
            SessionContainerView(minutes: request.minutes, focus: request.focus)
        }
        .sheet(isPresented: $showCapture) {
            QuickCaptureView()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let (ja, en) = switch hour {
        case 4..<11: ("おはようございます", "Good morning")
        case 11..<18: ("こんにちは", "Good afternoon")
        default: ("こんばんは", "Good evening")
        }
        let name = profiles.first?.name ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            LineStripe().frame(width: 36)
            Text(ja).font(.subheadline).foregroundStyle(Palette.inkSecondary)
            Text(name.isEmpty ? en : "\(en), \(name)")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Palette.ink)
        }
        .padding(.top, 12)
    }

    /// Basic iOS voices sound robotic; the natural ones are a free download the app can't do by itself.
    @ViewBuilder
    private var voiceTip: some View {
        if !voiceTipDismissed && AppleSpeechSynthesisProvider.englishVoiceIsBasic && !NaturalEnglishVoice.shared.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Get a natural English voice", systemImage: "waveform.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button { voiceTipDismissed = true } label: { Image(systemName: "xmark") }
                        .foregroundStyle(Palette.inkSecondary)
                        .accessibilityLabel("Dismiss")
                }
                Text("Your iPhone only has a basic English voice, which sounds robotic. In the iPhone's Settings › Accessibility › Spoken Content (Read & Speak) › Voices › English, download a voice marked Enhanced or Premium. Hanaseru will use it automatically.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.line.opacity(0.06), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
    }

    /// A free Apple ID signs the app for 7 days; warn two days ahead so practice isn't cut off.
    @ViewBuilder
    private var expiryBanner: some View {
        if let days = InstallInfo.daysLeft(), days <= 2, let expiry = InstallInfo.expiryText {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(days == 0 ? "Reinstall today" : "Reinstall within \(days) day\(days == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text("This install stops opening on \(expiry). Reinstall with Sideloadly and the same Apple ID to keep your progress — and keep a backup from Settings, just in case.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            } icon: {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Palette.caution)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
    }

    private var timePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ja: "今日は何分ありますか？", en: "How much time do you have?")
            HStack(spacing: 8) {
                ForEach(timeOptions, id: \.self) { option in
                    ChoiceChip(title: "\(option)", subtitle: "min", isSelected: minutes == option) { minutes = option }
                        .accessibilityIdentifier("time-\(option)")
                }
            }
        }
    }

    private var focusPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ja: "練習", en: "Practice")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SessionFocus.allCases, id: \.self) { option in
                        ChoiceChip(title: option.title, isSelected: focus == option) { focusRaw = option.rawValue }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// Every conversation, to start from any line — and the words used so far.
    private var scenesCard: some View {
        VStack(spacing: 10) {
            NavigationLink { ScenesView() } label: {
                linkRow("bubble.left.and.bubble.right", "Scenes", "Start any conversation from any line")
            }
            .accessibilityIdentifier("open-scenes")
            NavigationLink { TranslateView() } label: {
                linkRow("character.bubble", "Translate", "Say it in English, hear natural Japanese")
            }
            .accessibilityIdentifier("open-translate")
            NavigationLink { VocabularyView() } label: {
                linkRow("character.book.closed.ja", "My vocabulary", "Every word and line you've practised")
            }
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Palette.line)
                .frame(width: 44, height: 44)
                .background(Palette.line.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Palette.inkSecondary)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }

    private var heardThisCard: some View {
        Button { showCapture = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "ear.badge.waveform")
                    .font(.title2)
                    .foregroundStyle(Palette.line)
                    .frame(width: 44, height: 44)
                    .background(Palette.line.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("I heard this").font(.headline).foregroundStyle(Palette.ink)
                    Text("Capture a phrase from work in seconds").font(.footnote).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Palette.line)
            }
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var myJapaneseCard: some View {
        if !phrases.isEmpty || !mistakes.isEmpty {
            PracticeCard {
                SectionLabel(ja: "私の日本語", en: "My Japanese")
                ForEach(phrases.prefix(3)) { phrase in
                    JapaneseTextView(japanese: phrase.japanese, kana: phrase.kana, english: phrase.english, style: .body)
                }
                if let top = mistakes.first(where: { $0.occurrences >= 2 }) {
                    Divider()
                    Label {
                        Text("Recurring: \(top.type.displayName) — \(top.correction)")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }
}

struct SessionRequest: Identifiable {
    let id = UUID()
    let minutes: Int
    let focus: SessionFocus
}
