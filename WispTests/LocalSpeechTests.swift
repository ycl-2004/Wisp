import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import Wisp

final class LocalSpeechTests: XCTestCase {
    // MARK: Preferences

    func testOldPreferencesMigrateAndNewChoicesPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wisp-local-speech-" + UUID().uuidString))
        defaults.set(Data(#"{"mode":"both","locale":"zh-CN","savesAudio":true}"#.utf8), forKey: ListeningPreferences.key)
        var preferences = ListeningPreferences.load(from: defaults)
        XCTAssertEqual(preferences.mode, .both)
        XCTAssertEqual(preferences.locale, "zh-CN")
        XCTAssertTrue(preferences.savesAudio)
        XCTAssertNil(preferences.recognitionEngine)
        XCTAssertNil(preferences.localLanguage)

        // 0.3 stored SenseVoice by name; it must land on the folder it always loaded.
        defaults.set(Data(#"{"mode":"microphone","locale":"en-US","savesAudio":false,"recognitionEngine":"senseVoice","senseVoiceLanguage":"yue"}"#.utf8),
                     forKey: ListeningPreferences.key)
        preferences = ListeningPreferences.load(from: defaults)
        XCTAssertEqual(preferences.recognitionEngine, .local(LocalSpeechCatalog.legacySenseVoiceID))
        XCTAssertEqual(preferences.localLanguage, "yue")

        preferences.recognitionEngine = .local("org/model-a")
        preferences.localLanguage = "ja"
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), preferences)
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: ListeningPreferences.key)), as: UTF8.self)
        XCTAssertTrue(saved.contains(#""senseVoiceLanguage":"ja""#), saved)
        XCTAssertTrue(saved.contains("local:org"), saved)

        preferences.recognitionEngine = .appleSpeech
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults).recognitionEngine, .appleSpeech)
        XCTAssertNil(ListeningEngine(rawValue: "local:"))
        XCTAssertTrue(ListeningEngine.appleSpeech.requiresSpeechAuthorization)
        XCTAssertFalse(ListeningEngine.local("x").requiresSpeechAuthorization)
    }

    func testEachFamilyFallsBackToItsOwnDefaultLanguage() {
        let senseVoice = SenseVoiceFamily(), qwen = Qwen3ASRFamily()
        XCTAssertEqual(senseVoice.language(for: "yue"), "yue")
        XCTAssertEqual(senseVoice.language(for: "fr"), "auto")
        XCTAssertEqual(qwen.language(for: "zh"), "auto")
        XCTAssertEqual(qwen.languages, ["auto"])
    }

    // MARK: ONNX header

    func testONNXHeaderReadsMetadataAndRejectsDamagedFiles() throws {
        let folder = try temporaryFolder()
        let good = folder.appendingPathComponent("good.onnx")
        let bytes = Self.onnx(metadata: ["model_type": "fixture", "vocab_size": "3"], graphSize: 300_000)
        try Data(bytes).write(to: good)
        XCTAssertEqual(try ONNXModelInfo(contentsOf: good).metadata, ["model_type": "fixture", "vocab_size": "3"])

        let cases: [String: [UInt8]] = [
            "truncated": Array(bytes.dropLast()),
            "no graph": Self.field(14, Self.entry("k", "v")),
            "text": Array("hello, this is not a model".utf8),
            "empty": [],
            "group": [0x0B],   // field 1, wire type 3: onnx.proto has no groups
        ]
        for (name, bytes) in cases {
            let url = folder.appendingPathComponent(name + ".onnx")
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try ONNXModelInfo(contentsOf: url), name)
        }
        XCTAssertThrowsError(try ONNXModelInfo(contentsOf: folder.appendingPathComponent("absent.onnx")))
    }

    // MARK: Discovery

    func testScanOffersOnlyFoldersAFamilyAccepts() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        try Self.makeSenseVoice(at: root.appendingPathComponent("k2-fsa/sense-voice-a"))
        // A recognized model's own subfolders are never offered as further models.
        try Self.makeSenseVoice(at: root.appendingPathComponent("k2-fsa/sense-voice-a/test_wavs"))
        try Self.makeSenseVoice(at: root.appendingPathComponent("k2-fsa/sense-voice-b"), bothPrecisions: true)
        try Self.makeQwen(at: root.appendingPathComponent("k2-fsa/qwen3-asr"))
        try Self.makeSenseVoice(at: root.appendingPathComponent("group/org/nested"))           // depth 3: found
        try Self.makeSenseVoice(at: root.appendingPathComponent("a/b/c/too-deep"))             // depth 4: ignored
        try Self.makeSenseVoice(at: root.appendingPathComponent(".cache/hidden"))
        try Self.makeSenseVoice(at: outside.appendingPathComponent("linked-target"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("k2-fsa/linked"),
                                                   withDestinationURL: outside.appendingPathComponent("linked-target"))
        // Same file names as SenseVoice, but a different architecture's metadata: offering it would
        // let sherpa-onnx end the process on load.
        try Self.makeSenseVoice(at: root.appendingPathComponent("k2-fsa/paraformer"), metadata: ["vocab_size": "8404", "lfr_window_size": "7"])
        try Self.makeSenseVoice(at: root.appendingPathComponent("k2-fsa/damaged"), truncate: true)
        try Self.makeQwen(at: root.appendingPathComponent("k2-fsa/qwen-incomplete"), skipping: "merges.txt")

        let models = LocalSpeechCatalog.scan(root: root)
        XCTAssertEqual(models.map(\.id), ["group/org/nested", "k2-fsa/linked", "k2-fsa/sense-voice-a",
                                          "k2-fsa/sense-voice-b", "k2-fsa/qwen3-asr"])
        XCTAssertEqual(models.map(\.family.title), ["SenseVoice", "SenseVoice", "SenseVoice", "SenseVoice", "Qwen3-ASR"])
        let both = try XCTUnwrap(models.first { $0.id == "k2-fsa/sense-voice-b" })
        XCTAssertEqual(both.files["model"]?.lastPathComponent, "model.int8.onnx")
        let qwen = try XCTUnwrap(models.last)
        XCTAssertEqual(LocalSpeechCatalog.title(for: qwen, among: models), "Qwen3-ASR")
        XCTAssertEqual(LocalSpeechCatalog.title(for: both, among: models), "SenseVoice · sense-voice-b")
        XCTAssertEqual(qwen.files["tokenizer"]?.lastPathComponent, "tokenizer")

        guard case .ready(let ready) = LocalSpeechCatalog.availability(id: "k2-fsa/qwen3-asr", root: root) else {
            return XCTFail("Qwen3-ASR fixture should be ready")
        }
        XCTAssertEqual(ready.family.title, "Qwen3-ASR")
        for id in ["k2-fsa/paraformer", "k2-fsa/damaged", "k2-fsa/qwen-incomplete"] {
            guard case .unrecognized = LocalSpeechCatalog.availability(id: id, root: root) else { return XCTFail(id) }
        }
        for id in ["k2-fsa/renamed", "../outside", "", "k2-fsa/../k2-fsa/qwen3-asr"] {
            guard case .missing = LocalSpeechCatalog.availability(id: id, root: root) else { return XCTFail(id) }
        }
        XCTAssertTrue(LocalSpeechCatalog.scan(root: root.appendingPathComponent("absent")).isEmpty)
    }

    func testFamiliesThatFailValidationThrowInsteadOfCrashing() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for family in LocalSpeechCatalog.families {
            let files = ["model", "tokens", "frontend", "encoder", "decoder", "tokenizer"].reduce(into: [String: URL]()) {
                $0[$1] = folder.appendingPathComponent($1)
            }
            let model = LocalSpeechModel(id: "missing", folder: folder, family: family, files: files)
            do {
                _ = try await LocalSpeechRecognition.load(model, language: "auto")
                XCTFail("\(family.title) loaded without files")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(family.title), error.localizedDescription)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Audio

    func testStereo48kConversionPreservesDurationAcrossBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            for channel in 0..<2 {
                let data = try XCTUnwrap(buffer.floatChannelData?[channel])
                for frame in 0..<4800 { data[frame] = 0.25 }
            }
            buffers.append(buffer)
        }
        let samples = try LocalSpeechRecognition.samples(from: buffers)
        XCTAssertEqual(samples.count, 16_000, accuracy: 32)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertEqual(samples[8000], 0.25, accuracy: 0.03)
        XCTAssertEqual(try LocalSpeechRecognition.samples(from: []), [])
    }

    func testQuietGateSkipsSilenceAndNoiseButNotSpeech() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        func batch(peak: Float, burst: Float = 0) throws -> ListeningSpeechScheduler.Batch {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let data = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<48_000 { data[frame] = (frame % 2 == 0 ? 1 : -1) * peak }
            // A short syllable in the middle of an otherwise silent second.
            for frame in 20_000..<26_000 { data[frame] += Float(sin(Double(frame) * 0.2)) * burst }
            return .init(source: .microphone, offset: 0, duration: 1, buffers: [buffer])
        }
        XCTAssertTrue(LocalSpeechRecognition.isSilent(try batch(peak: 0)))
        XCTAssertTrue(LocalSpeechRecognition.isSilent(try batch(peak: 0.003)))
        XCTAssertFalse(LocalSpeechRecognition.isSilent(try batch(peak: 0.001, burst: 0.05)))
        XCTAssertFalse(LocalSpeechRecognition.isSilent(try batch(peak: 0.2)))
    }

    /// Loads every model actually installed on this Mac and transcribes the samples it ships with,
    /// whole and as the four-second batches live captions send. Timings go to the report file.
    func testEveryInstalledModelTranscribesItsOwnSamples() async throws {
        let models = LocalSpeechCatalog.scan()
        guard !models.isEmpty else { throw XCTSkip("No local speech model is installed on this test machine") }
        var report: [String] = []
        for model in models {
            var started = Date()
            let engine = try await LocalSpeechRecognition.load(model, language: "auto")
            report.append("## \(model.id) (\(model.family.title)) — load \(Self.seconds(since: started))")
            let samples = model.folder.appendingPathComponent("test_wavs")
            let wavs = ((try? FileManager.default.contentsOfDirectory(atPath: samples.path)) ?? [])
                .filter { $0.hasSuffix(".wav") }.sorted()
            XCTAssertFalse(wavs.isEmpty, model.id)
            var decoded = 0
            for name in wavs {
                let buffer = try Self.read(samples.appendingPathComponent(name))
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                guard duration <= 30 else { report.append("- \(name): \(Int(duration)) s, longer than one batch; skipped"); continue }
                started = Date()
                let text = try await Self.transcribe(buffer, with: engine)
                report.append("- \(name) (\(String(format: "%.1f", duration)) s) in \(Self.seconds(since: started)): \(text)")
                XCTAssertFalse(text.isEmpty, "\(model.id) \(name)")
                if name == "en.wav", model.family is SenseVoiceFamily { XCTAssertTrue(text.lowercased().contains("tribal chieftain"), text) }
                decoded += 1
            }
            XCTAssertGreaterThan(decoded, 0, model.id)
            // Live captions arrive as batches of at most four seconds; each must decode well inside
            // the scheduler's ten-second limit, and on average faster than real time.
            let first = try Self.read(samples.appendingPathComponent(wavs[0]))
            let slice = try XCTUnwrap(Self.prefix(first, seconds: 4))
            var slowest = 0.0
            for _ in 0..<3 {
                started = Date()
                _ = try await Self.transcribe(slice, with: engine)
                slowest = max(slowest, Date().timeIntervalSince(started))
            }
            report.append("- 4 s batch, slowest of 3: \(String(format: "%.2f", slowest)) s")
            XCTAssertLessThan(slowest, 4, "\(model.id) cannot keep up with live captions")
            // SenseVoice would transcribe this as a stray "그."; the quiet gate must keep it out.
            let silence = try XCTUnwrap(Self.silence(like: first, seconds: 2))
            let silent = try await Self.transcribe(silence, with: engine)
            XCTAssertEqual(silent, "", model.id)
            // The gate must not swallow speech: count one-second slices of the model's own
            // speech samples that it would skip.
            var slices = 0, skipped = 0
            for name in wavs {
                let buffer = try Self.read(samples.appendingPathComponent(name))
                let second = Int(buffer.format.sampleRate)
                for start in stride(from: 0, to: Int(buffer.frameLength) - second, by: second) {
                    let slice = try XCTUnwrap(Self.slice(buffer, from: start, frames: second))
                    slices += 1
                    if LocalSpeechRecognition.isSilent(.init(source: .application, offset: 0, duration: 1, buffers: [slice])) {
                        skipped += 1
                    }
                }
            }
            report.append("- quiet gate: \(skipped) of \(slices) one-second speech-sample slices skipped")
        }
        let text = report.joined(separator: "\n")
        try text.write(to: URL(fileURLWithPath: "/private/tmp/wisp-local-speech-report.txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Settings

    @MainActor
    func testTranscriptionSettingsRenderForDiscoveredModels() throws {
        let listening = ListeningModel.shared
        let oldEngine = listening.engine, oldEnabled = listening.isEnabled
        defer { listening.engine = oldEngine; listening.isEnabled = oldEnabled }
        listening.isEnabled = true
        let installed = LocalSpeechCatalog.scan()
        listening.engine = installed.last.map { .local($0.id) } ?? .local(LocalSpeechCatalog.legacySenseVoiceID)
        let view = NSHostingView(rootView: AudioSettingsView().frame(width: 620, height: 850))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 850), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scanned = expectation(description: "scan")
        let observer = LocalSpeechCatalog.shared.$isScanning.dropFirst().filter { !$0 }.sink { _ in scanned.fulfill() }
        defer { observer.cancel() }
        view.layoutSubtreeIfNeeded()
        wait(for: [scanned], timeout: 10)
        XCTAssertEqual(LocalSpeechCatalog.shared.models.map(\.id), installed.map(\.id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/wisp-local-speech-settings.png"))
        listening.isEnabled = false
        XCTAssertFalse(listening.canStart)
        XCTAssertFalse(listening.isActive)
    }
}

// MARK: - Fixtures

private extension LocalSpeechTests {
    static let senseVoiceMetadata = ["vocab_size", "lfr_window_size", "lfr_window_shift", "normalize_samples",
                                     "with_itn", "without_itn", "lang_auto", "lang_zh", "lang_en", "lang_ja",
                                     "lang_ko", "lang_yue", "neg_mean", "inv_stddev"]
        .reduce(into: [String: String]()) { $0[$1] = "1" }

    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-local-speech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func makeSenseVoice(at folder: URL, metadata: [String: String] = senseVoiceMetadata,
                               bothPrecisions: Bool = false, truncate: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var model = onnx(metadata: metadata)
        if truncate { model.removeLast(3) }
        try Data(model).write(to: folder.appendingPathComponent("model.int8.onnx"))
        if bothPrecisions { try Data(model).write(to: folder.appendingPathComponent("model.onnx")) }
        try Data("<blk> 0\n".utf8).write(to: folder.appendingPathComponent("tokens.txt"))
    }

    static func makeQwen(at folder: URL, skipping: String? = nil) throws {
        let tokenizer = folder.appendingPathComponent("tokenizer")
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        for name in ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx"] {
            try Data(onnx(metadata: [:])).write(to: folder.appendingPathComponent(name))
        }
        for name in ["vocab.json", "merges.txt", "tokenizer_config.json"] where name != skipping {
            try Data("{}".utf8).write(to: tokenizer.appendingPathComponent(name))
        }
    }

    static func onnx(metadata: [String: String], graphSize: Int = 64) -> [UInt8] {
        var bytes: [UInt8] = [0x08, 0x08]                                     // ir_version = 8
        bytes += field(7, [UInt8](repeating: 0x2A, count: graphSize))         // graph, skipped unread
        for key in metadata.keys.sorted() { bytes += field(14, entry(key, metadata[key]!)) }
        return bytes
    }

    static func entry(_ key: String, _ value: String) -> [UInt8] {
        field(1, Array(key.utf8)) + field(2, Array(value.utf8))
    }

    static func field(_ number: UInt64, _ payload: [UInt8]) -> [UInt8] {
        varint(number << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }

    static func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return buffer
    }

    static func prefix(_ buffer: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer? {
        slice(buffer, from: 0, frames: min(Int(buffer.frameLength), Int(buffer.format.sampleRate * seconds)))
    }

    static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, frames: Int) -> AVAudioPCMBuffer? {
        guard start + frames <= Int(buffer.frameLength),
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + start, count: frames)
        }
        return copy
    }

    static func silence(like buffer: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(buffer.format.sampleRate * seconds)
        guard let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let channels = silence.floatChannelData else { return nil }
        silence.frameLength = frames
        for channel in 0..<Int(buffer.format.channelCount) { channels[channel].update(repeating: 0, count: Int(frames)) }
        return silence
    }

    static func transcribe(_ buffer: AVAudioPCMBuffer, with engine: LocalSpeechRecognition) async throws -> String {
        let batch = ListeningSpeechScheduler.Batch(source: .application, offset: 0,
            duration: Double(buffer.frameLength) / buffer.format.sampleRate, buffers: [buffer])
        let result: ListeningSpeechScheduler.Update = await withCheckedContinuation { continuation in
            _ = engine.recognize(batch) { continuation.resume(returning: $0) }
        }
        if let error = result.error { throw error }
        XCTAssertTrue(result.isFinal)
        return result.text ?? ""
    }

    static func seconds(since start: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(start))
    }
}


extension LocalSpeechTests {
    /// Reading ~/Documents raises a macOS prompt, so Settings may scan by itself only after the
    /// user asked once or while a local model is already the chosen engine.
    func testSettingsNeverScanDocumentsUnasked() {
        XCTAssertFalse(LocalSpeechCatalog.scansAutomatically(for: .appleSpeech, requested: false))
        XCTAssertTrue(LocalSpeechCatalog.scansAutomatically(for: .appleSpeech, requested: true))
        XCTAssertTrue(LocalSpeechCatalog.scansAutomatically(for: .local("k2-fsa/model"), requested: false))
    }
}

extension LocalSpeechTests {
    func testChineseScriptConvertsBothWaysAndDefaultsToSimplified() throws {
        XCTAssertEqual(ChineseScript.simplified.apply(to: "開放時間：早上九點至下午五點"), "开放时间：早上九点至下午五点")
        XCTAssertEqual(ChineseScript.traditional.apply(to: "开放时间：早上九点"), "開放時間：早上九點")
        XCTAssertEqual(ChineseScript.original.apply(to: "開放時間"), "開放時間")
        XCTAssertEqual(ChineseScript.simplified.apply(to: "Hello, 50 pieces"), "Hello, 50 pieces")
        XCTAssertEqual(ChineseScript.default, .simplified)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wisp-script-" + UUID().uuidString))
        var preferences = ListeningPreferences.load(from: defaults)
        XCTAssertNil(preferences.chineseScript)
        preferences.chineseScript = .traditional
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults).chineseScript, .traditional)
    }

    /// Push-to-talk starts listening before the model is ready; a model that fails to load must
    /// come back as an error on the first batch, never as a crash or a silent empty answer.
    func testPreparedRecognitionReportsAFailedLoadOnTheFirstBatch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = LocalSpeechModel(id: "missing", folder: folder, family: Qwen3ASRFamily(),
                                     files: ["frontend": folder, "encoder": folder, "decoder": folder, "tokenizer": folder])
        let engine = LocalSpeechRecognition.prepare(model, language: "auto", script: .simplified)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for frame in 0..<16_000 { buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.05)) * 0.3 }
        let batch = ListeningSpeechScheduler.Batch(source: .microphone, offset: 0, duration: 1, buffers: [buffer])
        let result: ListeningSpeechScheduler.Update = await withCheckedContinuation { continuation in
            _ = engine.recognize(batch) { continuation.resume(returning: $0) }
        }
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.localizedDescription.contains("Qwen3-ASR"), error.localizedDescription)
    }

    @MainActor
    func testPushToTalkStaysIdleWhenVoiceInputIsOff() {
        let listening = ListeningModel.shared, pushToTalk = PushToTalk.shared
        let enabled = listening.isEnabled
        defer { listening.isEnabled = enabled }
        listening.isEnabled = false
        pushToTalk.begin()
        XCTAssertFalse(pushToTalk.isActive)
        pushToTalk.end()
        XCTAssertFalse(pushToTalk.isActive)
        XCTAssertEqual(PushToTalk.minimumHold, 0.3)
    }

    /// The real models, loaded the way push-to-talk loads them: capture would already be running,
    /// so the first decode has to wait for the load, and Chinese comes out in the chosen script.
    func testInstalledModelsDecodeRightAfterPrepareInTheChosenScript() async throws {
        let models = LocalSpeechCatalog.scan()
        let zh = models.first { $0.family is SenseVoiceFamily }?.folder.appendingPathComponent("test_wavs/zh.wav")
        guard !models.isEmpty, let zh, FileManager.default.fileExists(atPath: zh.path) else {
            throw XCTSkip("No local speech model with a Chinese sample is installed on this test machine")
        }
        let buffer = try Self.read(zh)
        var report: [String] = []
        for model in models {
            let started = Date()
            let engine = LocalSpeechRecognition.prepare(model, language: "auto", script: .simplified)
            let text = try await Self.transcribe(buffer, with: engine)
            report.append("\(model.family.title): \(text) (load + first decode \(Self.seconds(since: started)))")
            XCTAssertFalse(text.isEmpty, model.id)
            XCTAssertEqual(text, ChineseScript.simplified.apply(to: text), "\(model.id) returned Traditional characters: \(text)")
        }
        try report.joined(separator: "\n").write(to: URL(fileURLWithPath: "/private/tmp/wisp-prepare-report.txt"), atomically: true, encoding: .utf8)
    }
}
