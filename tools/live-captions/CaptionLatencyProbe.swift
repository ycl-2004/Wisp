// Feeds sentence recordings to Apple's streaming recognizer at real-time pace, with a 1.5 s
// pause after each, and reports how long after each sentence ends its caption keeps changing.
// Same recognizer options as Wisp's StreamingSpeech. Nothing is saved.
//
//   say -v Tingting -o /tmp/s1.aiff "你能说一下这个 folder 里面的 API 是怎么调用的吗？"
//   swiftc -parse-as-library tools/live-captions/CaptionLatencyProbe.swift -o /tmp/caption-probe
//   /tmp/caption-probe zh-CN /tmp/s1.aiff [/tmp/s2.aiff ...]
import AVFoundation
import Speech

final class Log: @unchecked Sendable {
  private let lock = NSLock()
  private var changes: [Double] = []
  private var finals: [String] = []
  private var volatile = ""
  func record(_ time: Double, text: String, isFinal: Bool) {
    lock.withLock {
      changes.append(time)
      if isFinal { finals.append(text); volatile = "" } else { volatile = text }
    }
  }
  var snapshot: (changes: [Double], text: String) { lock.withLock { (changes, (finals + [volatile]).joined()) } }
}

@main struct CaptionLatencyProbe {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { print("usage: caption-probe <locale> <file>..."); exit(2) }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: arguments[0])) else {
      print("locale not supported"); exit(1)
    }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: format)
    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    let start = Date()
    let log = Log()
    let reader = Task {
      for try await result in transcriber.results {
        log.record(Date().timeIntervalSince(start), text: String(result.text.characters), isFinal: result.isFinal)
      }
    }
    try await analyzer.start(inputSequence: stream)
    var fed = 0.0
    func feed(_ buffer: AVAudioPCMBuffer) async throws {
      input.yield(AnalyzerInput(buffer: buffer))
      fed += Double(buffer.frameLength) / format.sampleRate
      let wait = fed - Date().timeIntervalSince(start)
      if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }
    let chunk = AVAudioFrameCount(format.sampleRate / 10)
    var ends: [Double] = []
    for path in arguments.dropFirst() {
      let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
      let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
      try file.read(into: whole)
      let converter = AVAudioConverter(from: file.processingFormat, to: format)!
      let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity:
        AVAudioFrameCount(Double(file.length) * format.sampleRate / file.processingFormat.sampleRate) + 1024)!
      var handedOver = false
      var error: NSError?
      converter.convert(to: converted, error: &error) { _, state in
        if handedOver { state.pointee = .endOfStream; return nil }
        handedOver = true; state.pointee = .haveData; return whole
      }
      let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
      var position: AVAudioFrameCount = 0
      while position < converted.frameLength {
        let count = min(chunk, converted.frameLength - position)
        let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        piece.frameLength = count
        memcpy(piece.audioBufferList.pointee.mBuffers.mData!,
               converted.audioBufferList.pointee.mBuffers.mData! + Int(position) * bytesPerFrame,
               Int(count) * bytesPerFrame)
        try await feed(piece)
        position += count
      }
      ends.append(Date().timeIntervalSince(start))
      for _ in 0..<15 {
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        silence.frameLength = chunk
        memset(silence.audioBufferList.pointee.mBuffers.mData!, 0, Int(chunk) * bytesPerFrame)
        try await feed(silence)
      }
    }
    input.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = await reader.result
    let (changes, text) = log.snapshot
    for (index, end) in ends.enumerated() {
      let settled = changes.filter { $0 > end && $0 <= end + 1.5 }.max() ?? end
      print(String(format: "sentence %d ends %.2f s; caption settles %.2f s later", index + 1, end, settled - end))
    }
    print("text:", text)
  }
}
