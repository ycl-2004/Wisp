import Foundation

/// The custom metadata of an ONNX model, read without loading its weights.
///
/// Wisp checks a model before offering it because sherpa-onnx cannot fail gracefully: it ends the
/// process (`_Exit`) when a model lacks a metadata key its family expects, and ONNX Runtime throws
/// through the C API on a truncated file. Neither library exposes metadata short of building a full
/// session (about 1 GB of weights for Qwen3-ASR), and generating Swift for onnx.proto would add a
/// protobuf dependency for one field, so the `ModelProto` top level is walked here instead. Weights
/// sit inside length-delimited fields and are skipped without being read.
/// https://github.com/onnx/onnx/blob/main/onnx/onnx.proto — `graph` = 7, `metadata_props` = 14
/// https://protobuf.dev/programming-guides/encoding/
struct ONNXModelInfo {
    struct Malformed: Error {}

    let metadata: [String: String]

    init(contentsOf url: URL) throws {
        // Mapped, so a skipped field is never paged in.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var metadata: [String: String] = [:]
        var hasGraph = false
        try data.withUnsafeBytes { bytes in
            var reader = ProtobufReader(bytes)
            // Every field must end exactly at the end of the file; a partial download does not.
            while !reader.isAtEnd {
                let (field, wireType) = try reader.tag()
                guard wireType == 2 else { try reader.skip(wireType); continue }
                let value = try reader.lengthDelimited()
                if field == 7 { hasGraph = !value.isEmpty }
                if field == 14 {
                    let (key, text) = try Self.entry(value)
                    metadata[key] = text
                }
            }
        }
        // Arbitrary bytes can parse as protobuf by accident; a model always carries a graph.
        guard hasGraph else { throw Malformed() }
        self.metadata = metadata
    }

    /// `StringStringEntryProto`: key = 1, value = 2.
    private static func entry(_ bytes: UnsafeRawBufferPointer) throws -> (String, String) {
        var reader = ProtobufReader(bytes)
        var key = "", value = ""
        while !reader.isAtEnd {
            let (field, wireType) = try reader.tag()
            guard wireType == 2 else { try reader.skip(wireType); continue }
            let text = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            if field == 1 { key = text } else if field == 2 { value = text }
        }
        return (key, value)
    }
}

private struct ProtobufReader {
    private let bytes: UnsafeRawBufferPointer
    private var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func tag() throws -> (field: UInt64, wireType: UInt64) {
        let tag = try varint()
        guard tag >> 3 > 0 else { throw ONNXModelInfo.Malformed() }
        return (tag >> 3, tag & 7)
    }

    mutating func lengthDelimited() throws -> UnsafeRawBufferPointer {
        let length = try varint()
        guard length <= UInt64(bytes.count - offset) else { throw ONNXModelInfo.Malformed() }
        let value = UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + Int(length)])
        offset += Int(length)
        return value
    }

    /// onnx.proto uses no groups (wire types 3 and 4), so they are treated as corruption.
    mutating func skip(_ wireType: UInt64) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1: try advance(8)
        case 5: try advance(4)
        default: throw ONNXModelInfo.Malformed()
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard count <= bytes.count - offset else { throw ONNXModelInfo.Malformed() }
        offset += count
    }

    private mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: UInt64(0), to: 64, by: 7) {
            guard offset < bytes.count else { throw ONNXModelInfo.Malformed() }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw ONNXModelInfo.Malformed()
    }
}
