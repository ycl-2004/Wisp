import Foundation

/// Registry and discovery for local speech models. A folder is offered only when a registered
/// family recognizes it, so dropping another model of a known architecture into the shared folder
/// needs no rebuild. Wisp only reads this tree: it never downloads, copies or deletes models.
@MainActor
final class LocalSpeechCatalog: ObservableObject {
    static let shared = LocalSpeechCatalog()

    /// The registry, in picker order. A new architecture is one family plus one line here.
    nonisolated static let families: [any LocalSpeechFamily] = [SenseVoiceFamily(), Qwen3ASRFamily()]

    /// The Hugging Face tree other local tools already use (`<organization>/<model>`).
    nonisolated static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models", isDirectory: true)
    }

    /// 0.3 saved its only local engine by name; this is the folder it always loaded.
    nonisolated static let legacySenseVoiceID = "k2-fsa/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"

    /// `root/<organization>/<model>` is the usual depth; one more level allows a grouping folder.
    nonisolated static let maxDepth = 3

    enum Availability {
        case ready(LocalSpeechModel)
        /// The folder is gone, typically renamed or deleted after it was chosen.
        case missing
        /// The folder exists but no family accepts it: files incomplete, damaged or unsupported.
        case unrecognized
    }

    @Published private(set) var models: [LocalSpeechModel] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    /// Learned from a scan; checking it any other way would itself touch ~/Documents.
    @Published private(set) var rootExists = false

    /// Set once the user asks for a scan. Reading ~/Documents raises a macOS permission prompt,
    /// so Settings only scans on its own after that, or while a local model is selected: opening
    /// the page never raises the prompt unasked.
    private static let scanRequestedKey = "localSpeechScanRequested"

    private init() {}

    /// The user's explicit request; later visits to Settings keep the list current by themselves.
    func rescan() {
        UserDefaults.standard.set(true, forKey: Self.scanRequestedKey)
        startScan()
    }

    /// Keeps the list current, but is never the first thing to read ~/Documents.
    func refresh(for engine: ListeningEngine) {
        guard Self.scansAutomatically(for: engine, requested: UserDefaults.standard.bool(forKey: Self.scanRequestedKey)) else { return }
        startScan()
    }

    nonisolated static func scansAutomatically(for engine: ListeningEngine, requested: Bool) -> Bool {
        if case .local = engine { return true }
        return requested
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let (found, exists) = await Task.detached(priority: .userInitiated) {
                (Self.scan(), FileManager.default.fileExists(atPath: Self.root.path))
            }.value
            models = found
            rootExists = exists
            hasScanned = true
            isScanning = false
        }
    }

    func model(id: String) -> LocalSpeechModel? { models.first { $0.id == id } }

    func title(for model: LocalSpeechModel) -> String { Self.title(for: model, among: models) }

    /// The family name, plus the folder when two models of one family would read the same.
    nonisolated static func title(for model: LocalSpeechModel, among models: [LocalSpeechModel]) -> String {
        let twins = models.filter { $0.family.title == model.family.title }
        return twins.count > 1 ? "\(model.family.title) · \(model.folder.lastPathComponent)" : model.family.title
    }

    nonisolated static func scan(root: URL = root) -> [LocalSpeechModel] {
        var found: [LocalSpeechModel] = []
        func visit(_ folder: URL, path: [String]) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            if !path.isEmpty, let model = detect(folder, id: path.joined(separator: "/"), names: Set(names)) {
                // A model's own subfolders (tokenizer/, test_wavs/) are never models themselves.
                found.append(model)
                return
            }
            guard path.count < maxDepth else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let child = folder.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                // Follows symbolic links, so a linked model folder is found; the depth limit
                // also bounds a link cycle.
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                visit(child, path: path + [name])
            }
        }
        visit(root, path: [])
        return found.sorted { lhs, rhs in
            let left = familyIndex(lhs.family), right = familyIndex(rhs.family)
            return left != right ? left < right : lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    /// Re-checks one saved folder directly, so starting a session never depends on scan timing.
    nonisolated static func availability(id: String, root: URL = root) -> Availability {
        let components = id.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return .missing }
        let folder = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return .missing }
        return detect(folder, id: id, names: Set(names)).map(Availability.ready) ?? .unrecognized
    }

    /// The saved model, or an error that says what to do about it.
    nonisolated static func readyModel(id: String) throws -> LocalSpeechModel {
        let path = "\n~/Documents/huggingface/models/" + id
        switch availability(id: id) {
        case .ready(let model):
            return model
        case .missing:
            throw ListeningFailure(message: String(localized: "找不到所选的本地模型。请在设置 → 音频中重新扫描，或换一个识别引擎。") + path)
        case .unrecognized:
            throw ListeningFailure(message: String(localized: "所选的本地模型文件不完整或格式不受支持。请重新下载，或换一个识别引擎。") + path)
        }
    }

    private nonisolated static func detect(_ folder: URL, id: String, names: Set<String>) -> LocalSpeechModel? {
        for family in families {
            if let files = family.files(in: folder, names: names) {
                return LocalSpeechModel(id: id, folder: folder, family: family, files: files)
            }
        }
        return nil
    }

    private nonisolated static func familyIndex(_ family: any LocalSpeechFamily) -> Int {
        families.firstIndex { type(of: $0) == type(of: family) } ?? families.count
    }
}
