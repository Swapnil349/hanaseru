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

    private let timeOptions = [2, 5, 10, 20, 30]
    private var focus: SessionFocus { SessionFocus(rawValue: focusRaw) ?? .surprise }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greeting
                    timePicker
                    focusPicker
                    PrimaryButton(title: "Start \(minutes)-minute session", systemImage: "headphones") {
                        activeSession = SessionRequest(minutes: minutes, focus: focus)
                    }
                    Text("Put your earphones in and your phone away — everything is spoken.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .padding(.top, -16)

                    heardThisCard
                    myJapaneseCard
                }
                .padding(Metrics.padding)
            }
            .background(Palette.background)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
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

    private var timePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ja: "今日は何分ありますか？", en: "How much time do you have?")
            HStack(spacing: 8) {
                ForEach(timeOptions, id: \.self) { option in
                    ChoiceChip(title: "\(option)", subtitle: "min", isSelected: minutes == option) { minutes = option }
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
