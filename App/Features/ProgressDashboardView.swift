import LearningCore
import SwiftData
import SwiftUI

/// Meaningful progress, not XP (spec §52–53). The learning map describes each area in words backed
/// by how many items have actually been practised, instead of inventing a score.
struct ProgressDashboardView: View {
    @Environment(AppEnvironment.self) private var app
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @Query private var knowledge: [KnowledgeRecord]
    @Query private var phrases: [PersonalPhraseRecord]
    @Query private var mistakes: [MistakeRecord]
    @Query private var profiles: [LearnerProfileRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    thisWeek
                    learningMap
                    if let level = profiles.first?.difficulty.level {
                        PracticeCard {
                            SectionLabel(ja: "現在の難易度", en: "Current challenge")
                            DifficultyIndicator(level: level)
                            Text("Adjusts automatically: speed, English support and response time change with how your sessions go.")
                                .font(.footnote).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                .padding(Metrics.padding)
            }
            .background(Palette.background)
            .navigationTitle("Progress")
        }
    }

    // MARK: - This week

    private var weekSessions: [SessionRecord] {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions.filter { $0.startedAt >= weekAgo }
    }

    private var thisWeek: some View {
        let week = weekSessions
        let listened = week.map(\.secondsListening).reduce(0, +)
        let spoken = week.map(\.secondsSpeaking).reduce(0, +)
        let conversations = week.filter { !$0.scenarioIDs.isEmpty }.count
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ja: "今週", en: "This week")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricTile(value: "\(Int(listened / 60))", label: "minutes listened", systemImage: "ear")
                MetricTile(value: "\(Int(spoken / 60))", label: "minutes spoken", systemImage: "mic")
                MetricTile(value: "\(conversations)", label: "conversations", systemImage: "bubble.left.and.bubble.right")
                MetricTile(value: "\(phrases.count)", label: "expressions captured", systemImage: "text.book.closed")
                MetricTile(value: "\(mistakes.filter { $0.occurrences >= 2 }.count)", label: "recurring mistakes", systemImage: "arrow.triangle.2.circlepath")
                MetricTile(value: "\(workTermsPractised)", label: "work items practised", systemImage: "tram")
            }
        }
    }

    // MARK: - Learning map

    private var states: [KnowledgeState] { knowledge.compactMap(\.state) }

    private var workTermsPractised: Int {
        states.filter { app.library.item(id: $0.itemID)?.track == .work && !$0.isNew }.count
    }

    private var learningMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ja: "学習マップ", en: "Learning map")
            PracticeCard {
                mapRow("Listening", states: states, dimension: .listening)
                mapRow("Speaking", states: states, dimension: .spokenRecall)
                mapRow("Using it in context", states: states, dimension: .context)
                mapRow("Clearly understood", states: states, dimension: .pronunciation)
                Divider()
                mapRow("Work Japanese", states: states.filter { app.library.item(id: $0.itemID)?.track == .work }, dimension: nil)
                mapRow("Everyday Japanese", states: states.filter { app.library.item(id: $0.itemID)?.track == .everyday }, dimension: nil)
            }
            Text("“Clearly understood” means speech recognition understood you. It isn't a pitch-accent score.")
                .font(.caption).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func mapRow(_ title: String, states: [KnowledgeState], dimension: SkillDimension?) -> some View {
        let practised = states.filter { state in
            if let dimension { return state.state(dimension).reviews > 0 }
            return !state.isNew
        }
        let strengths = practised.map { (state: KnowledgeState) -> Double in
            if let dimension { return state.state(dimension).strength }
            return state.mastery
        }
        let strength = strengths.isEmpty ? 0 : strengths.reduce(0, +) / Double(strengths.count)
        let band = Self.band(strength: strength, count: practised.count)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                Spacer()
                Text(band).font(.caption).foregroundStyle(Palette.inkSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule().fill(Palette.line).frame(width: proxy.size.width * strength)
                }
            }
            .frame(height: 6)
            Text(practised.isEmpty ? "Not practised yet" : "\(practised.count) items practised")
                .font(.caption2).foregroundStyle(Palette.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func band(strength: Double, count: Int) -> String {
        guard count >= 3 else { return count == 0 ? "—" : "Just started" }
        switch strength {
        case ..<0.4: return "Emerging"
        case ..<0.7: return "Developing"
        default: return "Comfortable"
        }
    }
}
