import Foundation
import LearningCore
import SessionCore
import SwiftData

/// `LearnerRepository` backed by SwiftData (spec §56, §58: local-first).
@MainActor
final class SwiftDataLearnerRepository: LearnerRepository {
    private let context: ModelContext
    private let encoder = JSONEncoder()

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Profile

    func profile() -> LearnerProfileRecord {
        if let existing = try? context.fetch(FetchDescriptor<LearnerProfileRecord>()).first {
            return existing
        }
        let profile = LearnerProfileRecord()
        context.insert(profile)
        persist()
        return profile
    }

    func setName(_ name: String) {
        profile().name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func snapshot() async -> LearnerSnapshot {
        let profile = profile()
        return LearnerSnapshot(name: profile.name, difficulty: profile.difficulty)
    }

    func saveDifficulty(_ difficulty: DifficultyProfile) async {
        profile().difficulty = difficulty
        persist()
    }

    // MARK: - Knowledge

    func knowledge(for itemIDs: [String]) async -> [String: KnowledgeState] {
        let ids = itemIDs
        let descriptor = FetchDescriptor<KnowledgeRecord>(predicate: #Predicate { ids.contains($0.itemID) })
        return states(from: (try? context.fetch(descriptor)) ?? [])
    }

    func allKnowledge() async -> [String: KnowledgeState] {
        states(from: (try? context.fetch(FetchDescriptor<KnowledgeRecord>())) ?? [])
    }

    func save(_ knowledge: KnowledgeState) async {
        guard let data = try? encoder.encode(knowledge) else { return }
        let id = knowledge.itemID
        let descriptor = FetchDescriptor<KnowledgeRecord>(predicate: #Predicate { $0.itemID == id })
        if let record = try? context.fetch(descriptor).first {
            record.stateData = data
            record.updatedAt = Date()
        } else {
            context.insert(KnowledgeRecord(itemID: id, stateData: data))
        }
        persist()
    }

    private func states(from records: [KnowledgeRecord]) -> [String: KnowledgeState] {
        var result: [String: KnowledgeState] = [:]
        for record in records {
            if let state = record.state { result[record.itemID] = state }
        }
        return result
    }

    // MARK: - Mistakes

    func record(_ mistake: MistakeObservation) async {
        let key = mistake.aggregationKey
        let descriptor = FetchDescriptor<MistakeRecord>(predicate: #Predicate { $0.key == key })
        if let record = try? context.fetch(descriptor).first {
            record.occurrences += 1
            record.lastSeen = mistake.date
            record.lastSaid = mistake.said
            if record.itemID == nil { record.itemID = mistake.itemID }
        } else {
            context.insert(MistakeRecord(observation: mistake))
        }
        persist()
    }

    func recurringMistakes(limit: Int) async -> [MistakeSummary] {
        var descriptor = FetchDescriptor<MistakeRecord>(sortBy: [
            SortDescriptor(\.occurrences, order: .reverse), SortDescriptor(\.lastSeen, order: .reverse),
        ])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(\.summary)
    }

    // MARK: - Personal phrases

    /// Personal phrases ready for spoken practice. Phrases captured only in romaji wait for the
    /// M2 lookup that turns them into Japanese; the voice engine can't practise them yet.
    func personalItems() async -> [LearningItem] {
        ((try? context.fetch(FetchDescriptor<PersonalPhraseRecord>())) ?? [])
            .filter { JapaneseText.containsJapanese($0.japanese) }
            .map(\.learningItem)
    }

    func addPhrase(japanese: String, kana: String, english: String, note: String, source: PhraseSource, track: Track) {
        context.insert(PersonalPhraseRecord(japanese: japanese, kana: kana, english: english, note: note, source: source, track: track))
        persist()
    }

    // MARK: - Sessions

    func record(_ summary: SessionSummary) async {
        context.insert(SessionRecord(summary: summary))
        persist()
    }

    func recentResults(limit: Int) async -> [ExerciseResult] {
        Array(recentSessions(10).reversed().flatMap(\.results).suffix(limit))
    }

    func recentScenarioIDs(limit: Int) async -> [String] {
        Array(recentSessions(5).reversed().flatMap(\.scenarioIDs).suffix(limit))
    }

    private func recentSessions(_ count: Int) -> [SessionRecord] {
        var descriptor = FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = count
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Privacy (spec §60)

    /// Removes every stored transcript of the learner's speech. Audio itself is never stored.
    func deleteVoiceData() {
        for record in (try? context.fetch(FetchDescriptor<MistakeRecord>())) ?? [] {
            record.lastSaid = ""
        }
        persist()
    }

    /// Deletes all learning data and the profile.
    func deleteEverything() {
        try? context.delete(model: KnowledgeRecord.self)
        try? context.delete(model: MistakeRecord.self)
        try? context.delete(model: SessionRecord.self)
        try? context.delete(model: PersonalPhraseRecord.self)
        try? context.delete(model: LearnerProfileRecord.self)
        persist()
    }

    private func persist() {
        do {
            try context.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error)")
        }
    }
}
