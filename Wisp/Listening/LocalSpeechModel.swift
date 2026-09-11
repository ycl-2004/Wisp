import Foundation
import SherpaOnnxC

/// One sherpa-onnx offline model architecture. A family recognizes its own folder layout and
/// fills in its own part of the recognizer config; discovery, loading, threading and decoding are
/// shared, so a new architecture is one conforming type plus one line in
/// `LocalSpeechCatalog.families`. Another model of a known architecture needs no code at all.
protocol LocalSpeechFamily: Sendable {
    /// Engine picker name, e.g. "SenseVoice".
    var title: String { get }

    /// Language hints the model accepts; the first is the default. `["auto"]` alone means the
    /// model identifies the language itself, so Wisp offers no choice.
    var languages: [String] { get }

    /// The files this family needs from `folder`, keyed by role, or nil when the folder is not
    /// this family's layout. `names` is the folder's own listing. Only headers may be read here:
    /// this runs for every candidate folder on every scan.
    func files(in folder: URL, names: Set<String>) -> [String: URL]?

    /// Writes this family's fields into a zeroed config. `files` came from `files(in:names:)`;
    /// every string must come from `strings` so it outlives the native call.
    func configure(_ config: inout SherpaOnnxOfflineModelConfig, files: [String: URL],
                   language: String, strings: CStringPool)
}

extension LocalSpeechFamily {
    /// The saved hint when this model accepts it, otherwise the model's default. The saved value
    /// is left alone, so switching models and back does not lose it.
    func language(for saved: String) -> String {
        languages.contains(saved) ? saved : languages[0]
    }

    /// The first candidate present as a readable, non-empty file. Candidates are in order of
    /// preference, so an int8 export wins when a folder ships both precisions.
    func file(_ candidates: [String], in folder: URL, names: Set<String>) -> URL? {
        candidates.lazy
            .filter(names.contains)
            .map { folder.appendingPathComponent($0) }
            .first(where: Self.isUsableFile)
    }

    /// Like `file`, but also requires an intact ONNX container carrying every key in `metadata`.
    func model(_ candidates: [String], in folder: URL, names: Set<String>,
               metadata: [String] = []) -> URL? {
        candidates.lazy
            .filter(names.contains)
            .map { folder.appendingPathComponent($0) }
            .first { url in
                guard Self.isUsableFile(url), let info = try? ONNXModelInfo(contentsOf: url) else { return false }
                return metadata.allSatisfy { info.metadata[$0]?.isEmpty == false }
            }
    }

    static func isUsableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
            && FileManager.default.isReadableFile(atPath: url.path)
    }
}

/// A folder some family recognized. Found by scanning, never stored: preferences keep `id`.
struct LocalSpeechModel: Identifiable {
    /// Folder path relative to `LocalSpeechCatalog.root`, stable across scans.
    let id: String
    let folder: URL
    let family: any LocalSpeechFamily
    let files: [String: URL]
}

/// Keeps C strings alive for one native call. sherpa-onnx config structs borrow `const char *`
/// until the recognizer copies them; `withCString` only nests, which does not scale to the four
/// paths some families need.
final class CStringPool {
    private var storage: [UnsafeMutablePointer<CChar>] = []

    func callAsFunction(_ string: String) -> UnsafePointer<CChar> {
        let pointer = strdup(string)!
        storage.append(pointer)
        return UnsafePointer(pointer)
    }

    /// A path a family resolved. A missing role becomes "", which sherpa-onnx's own validation
    /// rejects with a nil recognizer instead of crashing.
    func path(_ role: String, in files: [String: URL]) -> UnsafePointer<CChar> {
        self(files[role]?.path ?? "")
    }

    deinit { storage.forEach { free($0) } }
}
