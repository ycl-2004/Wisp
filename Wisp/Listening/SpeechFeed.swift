import AVFoundation

/// Turns one source's audio into caption updates. Every call arrives on the capture sink's
/// serial queue, never on a realtime audio thread.
protocol SpeechFeed: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio will come; what was appended is still recognized.
    func endAudio()
    /// Everything appended has been recognized (or the feed was cancelled).
    var isDrained: Bool { get }
    func cancel()
}

/// Converts whatever a capture delivers (48 kHz float from an app, the device format from the
/// microphone) into the one format a recognizer takes. The converter keeps its resampling state
/// between calls, so a buffer is handed over once and the rest of its samples come out with the
/// next one.
/// https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions
final class PCMConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(format: AVAudioFormat) {
        self.format = format
    }

    /// The buffer in `format`; it may hold no frames yet. nil when the conversion fails.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64)
        else { return nil }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !handedOver else { state.pointee = .noDataNow; return nil }
            handedOver = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || error != nil ? nil : output
    }
}
