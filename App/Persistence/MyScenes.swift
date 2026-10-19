import Foundation
import LearningCore
import Observation

/// The learner's own scenes (docs/MY-SCENES.md), kept as one JSON file in Application Support in the shape every
/// platform shares, newest first. Changes are written at once, so they survive the app being closed.
@Observable
@MainActor
final class MySceneStore {
    private(set) var scenes: [MyScene] = []
    /// Called after every change (the app rebuilds its library with the scenes in it).
    var onChange: (() -> Void)?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("my-scenes.json")
        }
        load()
    }

    func scene(id: String) -> MyScene? {
        scenes.first { $0.id == id }
    }

    /// Adds a scene, or replaces the one with the same id; it comes first in the list.
    func save(_ scene: MyScene) {
        scenes = [scene] + scenes.filter { $0.id != scene.id }
        changed()
    }

    func delete(id: String) {
        scenes.removeAll { $0.id == id }
        changed()
    }

    /// Adds the scenes in an exported file (one scene or a list); scenes already here with the same id are
    /// replaced. Returns how many were read.
    @discardableResult
    func importFile(_ data: Data) throws -> Int {
        let incoming = try MyScene.scenes(fromFile: data)
        var byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for scene in incoming { byID[scene.id] = scene }
        scenes = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        changed()
        return incoming.count
    }

    /// Everything from a backup.
    func replaceAll(_ scenes: [MyScene]) {
        self.scenes = scenes.sorted { $0.updatedAt > $1.updatedAt }
        changed()
    }

    /// One scene as a file to share ("Meeting the new team.json"), or nil if it couldn't be written.
    func exportFile(for scene: MyScene) -> URL? {
        let unsafe = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let title = scene.result.title.components(separatedBy: unsafe).joined().trimmingCharacters(in: .whitespaces)
        let name = (title.isEmpty ? "My scene" : String(title.prefix(60))) + ".json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try MyScene.file([scene]).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        scenes = ((try? MyScene.scenes(fromFile: data)) ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func changed() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(scenes).write(to: fileURL, options: .atomic)
        } catch {
            VoiceLog.add("my scenes couldn't be saved: \(error.localizedDescription)")
        }
        onChange?()
    }
}
