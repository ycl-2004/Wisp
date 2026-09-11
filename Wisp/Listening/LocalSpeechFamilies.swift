import Foundation
import SherpaOnnxC

/// SenseVoice Small exports from k2-fsa: one CTC model plus `tokens.txt`.
/// https://k2-fsa.github.io/sherpa/onnx/sense-voice/index.html
struct SenseVoiceFamily: LocalSpeechFamily {
    let title = "SenseVoice"
    let languages = ["auto", "zh", "en", "ja", "ko", "yue"]

    /// Every key sherpa-onnx 1.13.7 reads unconditionally from a SenseVoice model; a missing one
    /// ends the process. Paraformer and other CTC exports share the file names but not these keys.
    /// https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.7/sherpa-onnx/csrc/offline-sense-voice-model.cc
    private static let metadata = ["vocab_size", "lfr_window_size", "lfr_window_shift", "normalize_samples",
                                   "with_itn", "without_itn", "lang_auto", "lang_zh", "lang_en", "lang_ja",
                                   "lang_ko", "lang_yue", "neg_mean", "inv_stddev"]

    func files(in folder: URL, names: Set<String>) -> [String: URL]? {
        guard let model = model(["model.int8.onnx", "model.onnx"], in: folder, names: names, metadata: Self.metadata),
              let tokens = file(["tokens.txt"], in: folder, names: names) else { return nil }
        return ["model": model, "tokens": tokens]
    }

    func configure(_ config: inout SherpaOnnxOfflineModelConfig, files: [String: URL],
                   language: String, strings: CStringPool) {
        config.tokens = strings.path("tokens", in: files)
        config.sense_voice.model = strings.path("model", in: files)
        config.sense_voice.language = strings(language)
        config.sense_voice.use_itn = 1
    }
}

/// Qwen3-ASR exports from k2-fsa: a convolutional front end, an encoder and a decoder plus a
/// Hugging Face BPE tokenizer folder. The model identifies the spoken language itself.
/// https://k2-fsa.github.io/sherpa/onnx/qwen3-asr/index.html
struct Qwen3ASRFamily: LocalSpeechFamily {
    let title = "Qwen3-ASR"
    let languages = ["auto"]

    /// The tokenizer files sherpa-onnx's own config validation requires.
    private static let tokenizerFiles = ["vocab.json", "merges.txt", "tokenizer_config.json"]

    func files(in folder: URL, names: Set<String>) -> [String: URL]? {
        guard let frontend = model(["conv_frontend.int8.onnx", "conv_frontend.onnx"], in: folder, names: names),
              let encoder = model(["encoder.int8.onnx", "encoder.onnx"], in: folder, names: names),
              let decoder = model(["decoder.int8.onnx", "decoder.onnx"], in: folder, names: names) else { return nil }
        let tokenizer = folder.appendingPathComponent("tokenizer", isDirectory: true)
        guard Self.tokenizerFiles.allSatisfy({ Self.isUsableFile(tokenizer.appendingPathComponent($0)) }) else {
            return nil
        }
        return ["frontend": frontend, "encoder": encoder, "decoder": decoder, "tokenizer": tokenizer]
    }

    func configure(_ config: inout SherpaOnnxOfflineModelConfig, files: [String: URL],
                   language: String, strings: CStringPool) {
        config.qwen3_asr.conv_frontend = strings.path("frontend", in: files)
        config.qwen3_asr.encoder = strings.path("encoder", in: files)
        config.qwen3_asr.decoder = strings.path("decoder", in: files)
        config.qwen3_asr.tokenizer = strings.path("tokenizer", in: files)
        // Length limits stay at sherpa-onnx's defaults (512 total, 128 new tokens): Wisp sends
        // batches of a few seconds, far inside what the model decodes reliably (about 30 s).
    }
}
