import Foundation

/// Which words appear where: the vocabulary of a scene or a phrase, for word lists the learner can go back to.
public extension ContentLibrary {
    /// The words used in a scene: its target words first, then every listed word that appears in its lines.
    func vocabulary(in scenario: Scenario) -> [VocabularyTerm] {
        var text = [scenario.closingLine]
        for beat in scenario.beats {
            text.append(beat.line)
            text.append(contentsOf: beat.responses.map(\.japanese))
        }
        return terms(ids: scenario.targetTerms, appearingIn: text.joined(separator: " "))
    }

    /// The words used in a phrase item.
    func vocabulary(in item: LearningItem) -> [VocabularyTerm] {
        terms(ids: item.terms, appearingIn: item.japanese)
    }

    private func terms(ids: [String], appearingIn text: String) -> [VocabularyTerm] {
        var result = ids.compactMap { term(id: $0) }
        for candidate in vocabulary where !result.contains(where: { $0.id == candidate.id }) {
            // Kanji spellings only (or kana-only words of 3+ characters): short kana would match inside other words.
            let form = candidate.japanese
            let isKanaOnly = form == candidate.kana
            guard !form.isEmpty, !isKanaOnly || form.count >= 3 else { continue }
            if text.contains(form) { result.append(candidate) }
        }
        return result
    }
}
