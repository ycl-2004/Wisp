import AVFoundation
import SwiftUI
import XCTest
@testable import Wisp

final class SenseVoiceTests: XCTestCase {
    func testOldPreferencesSurviveEngineMigrationAndNewChoicesPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wisp-sensevoice-" + UUID().uuidString))
        defaults.set(Data(#"{"mode":"both","locale":"zh-CN","savesAudio":true}"#.utf8), forKey: ListeningPreferences.key)
        defer { defaults.removeObject(forKey: ListeningPreferences.key) }
        var preferences = ListeningPreferences.load(from: defaults)
        XCTAssertEqual(preferences.mode, .both)
        XCTAssertEqual(preferences.locale, "zh-CN")
        XCTAssertTrue(preferences.savesAudio)
        XCTAssertNil(preferences.recognitionEngine)
        preferences.recognitionEngine = .senseVoice
        preferences.senseVoiceLanguage = "auto"
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults), preferences)
        preferences.senseVoiceLanguage = "unsupported"
        preferences.save(to: defaults)
        XCTAssertEqual(ListeningPreferences.load(from: defaults).senseVoiceLanguage, "auto")
        XCTAssertFalse(ListeningRecognitionEngine.senseVoice.requiresSpeechAuthorization)
        XCTAssertTrue(ListeningRecognitionEngine.appleSpeech.requiresSpeechAuthorization)
    }

    func testMissingOrEmptyModelFilesFailWithoutCreatingAnything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SenseVoiceRecognition.validateModel(in: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("model.int8.onnx"))
        try Data("tokens".utf8).write(to: folder.appendingPathComponent("tokens.txt"))
        XCTAssertThrowsError(try SenseVoiceRecognition.validateModel(in: folder))
    }

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
        let samples = try SenseVoiceRecognition.samples(from: buffers)
        XCTAssertEqual(samples.count, 16_000, accuracy: 32)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertEqual(samples[8000], 0.25, accuracy: 0.03)
        XCTAssertEqual(try SenseVoiceRecognition.samples(from: []), [])
    }

    func testInstalledModelDecodesBundledEnglishAndChineseSamples() async throws {
        let folder = SenseVoiceRecognition.modelFolder
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.int8.onnx").path) else {
            throw XCTSkip("Shared SenseVoice model is not installed on this test machine")
        }
        let engine = try await SenseVoiceRecognition.load(language: "auto")
        for language in ["en", "zh"] {
            let file = try AVAudioFile(forReading: folder.appendingPathComponent("test_wavs/\(language).wav"))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let batch = ListeningSpeechScheduler.Batch(source: .application, offset: 12,
                duration: Double(buffer.frameLength) / buffer.format.sampleRate, buffers: [buffer])
            let result: ListeningSpeechScheduler.Update = await withCheckedContinuation { continuation in
                _ = engine.recognize(batch) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(result.error)
            XCTAssertTrue(result.isFinal)
            let text = try XCTUnwrap(result.text)
            XCTAssertFalse(text.isEmpty)
            if language == "en" { XCTAssertTrue(text.lowercased().contains("tribal chieftain"), text) }
            if language == "zh" { XCTAssertTrue(text.contains("时间") && text.contains("5"), text) }
            let attachment = XCTAttachment(string: "\(language): \(text)")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testSenseVoiceSettingsAndVoiceVisibilityRender() throws {
        let listening = ListeningModel.shared
        let oldEngine = listening.recognitionEngine, oldEnabled = listening.isEnabled
        defer { listening.recognitionEngine = oldEngine; listening.isEnabled = oldEnabled }
        listening.isEnabled = true
        listening.recognitionEngine = .senseVoice
        let view = NSHostingView(rootView: AudioSettingsView().frame(width: 620, height: 850))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 850), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/wisp-sensevoice-settings.png"))
        listening.isEnabled = false
        XCTAssertFalse(listening.canStart)
        listening.isEnabled = true
        XCTAssertEqual(listening.recognitionEngine, .senseVoice)
        XCTAssertFalse(listening.isActive)
    }
}
