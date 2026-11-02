import XCTest
@testable import Wisp

/// Audit round 4 (test-engineering lane): ONNXModelInfo robustness.
/// The type sits in the Linux closure but had NO harness tests — its
/// only coverage lives in WispTests/LocalSpeechTests.swift, which is
/// sherpa-bound and cannot run here. This file rebuilds the same
/// protobuf fixture (helpers mirrored from LocalSpeechTests) and adds
/// the fuzz matrix: every truncation point of a valid file, seeded
/// random garbage, and seeded mutations must throw or succeed with a
/// metadata subset — never crash. That contract matters: this parser
/// is the only thing standing between user-supplied model files and
/// sherpa-onnx's process-ending `_Exit` on malformed input.
final class ONNXFuzzTests: XCTestCase {

    // MARK: Fixture builders (mirrored from WispTests/LocalSpeechTests.swift)

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }

    private static func field(_ number: UInt64, _ payload: [UInt8]) -> [UInt8] {
        varint(number << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    private static func entry(_ key: String, _ value: String) -> [UInt8] {
        field(1, Array(key.utf8)) + field(2, Array(value.utf8))
    }

    private static func onnx(metadata: [String: String], graphSize: Int = 64) -> [UInt8] {
        var bytes: [UInt8] = [0x08, 0x08] // ir_version = 8
        bytes += field(7, [UInt8](repeating: 0x2A, count: graphSize))
        for key in metadata.keys.sorted() { bytes += field(14, entry(key, metadata[key]!)) }
        return bytes
    }

    private func parse(_ bytes: [UInt8]) throws -> ONNXModelInfo {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onnx-fuzz-\(UUID().uuidString).onnx")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ONNXModelInfo(contentsOf: url)
    }

    // MARK: Valid fixture

    func testValidFixtureRoundTripsMetadata() throws {
        let info = try parse(Self.onnx(metadata: ["model_type": "fixture", "vocab_size": "3"],
                                       graphSize: 300))
        XCTAssertEqual(info.metadata, ["model_type": "fixture", "vocab_size": "3"])
    }

    func testGraphOnlyFileSucceedsWithEmptyMetadata() throws {
        let info = try parse(Self.onnx(metadata: [:], graphSize: 10))
        XCTAssertEqual(info.metadata, [:])
    }

    // MARK: Truncation matrix

    /// Every strict prefix of a valid file: must throw, OR succeed with
    /// a subset of the full metadata (a prefix that ends exactly on a
    /// field boundary after the graph is itself a valid, graph-carrying
    /// protobuf — succeeding there is correct, not a bug).
    func testEveryTruncationPointThrowsOrYieldsASubset() {
        let full: [String: String] = ["model_type": "fixture", "vocab_size": "3"]
        let bytes = Self.onnx(metadata: full, graphSize: 40)
        for cut in 0..<bytes.count {
            let prefix = Array(bytes[..<cut])
            do {
                let info = try parse(prefix)
                for (key, value) in info.metadata {
                    XCTAssertEqual(full[key], value,
                                   "cut \(cut): invented metadata \(key)=\(value)")
                }
            } catch {
                // Expected for all cuts that land mid-field or pre-graph.
            }
        }
        // And the complete file succeeds with everything.
        XCTAssertEqual(try? parse(bytes).metadata, full)
    }

    // MARK: Garbage and mutations (seeded)

    func testRandomGarbageNeverCrashesAndRarelyParses() {
        var rng = SeededRNG(seed: 0x0FF1_CE00)
        var successes = 0
        for _ in 0..<300 {
            let bytes = rng.nextBytes(count: rng.nextInt(in: 0...80))
            if (try? parse(bytes)) != nil { successes += 1 }
        }
        // Arbitrary bytes CAN form a graph-carrying protobuf by luck,
        // but with random lengths that needs a valid tag+length+payload
        // alignment; anything above a handful signals the hasGraph /
        // exact-end checks stopped working.
        XCTAssertLessThan(successes, 10)
    }

    func testMutationsOfAValidFileNeverCrash() {
        let bytes = Self.onnx(metadata: ["model_type": "fixture"], graphSize: 40)
        var rng = SeededRNG(seed: 0x0FF1_CE01)
        for _ in 0..<200 {
            var mutated = bytes
            for _ in 0..<(1 + rng.nextInt(6)) {
                mutated[rng.nextInt(mutated.count)] = UInt8(rng.next() & 0xFF)
            }
            // Throw or succeed — the assertion is reaching this line.
            _ = try? parse(mutated)
        }
    }

    func testGarbageAfterAValidGraphIsRejectedUnlessWellFormed() {
        // A valid graph followed by a dangling tag byte: the walk must
        // not end "exactly at the end of the file" → Malformed.
        var bytes = Self.onnx(metadata: [:], graphSize: 10)
        bytes.append(0x72) // field 14, wire 2 — but no length follows
        XCTAssertThrowsError(try parse(bytes))
    }

    // MARK: Targeted malformed shapes

    func testTargetedMalformedInputsThrow() {
        let cases: [[UInt8]] = [
            [],                                            // empty
            [0x00],                                        // field number 0
            [0x0B],                                        // field 1, wire 3 (group: unused by onnx.proto)
            [0x0C],                                        // field 1, wire 4 (group end)
            [0x3A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F],          // graph field, length 4 GiB-1 > remaining
            [0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00], // varint longer than 10 bytes
            [0x3A, 0x00],                                  // graph present but empty → hasGraph false
            Array("hello, this is not a model".utf8),      // plain text
        ]
        for (index, bytes) in cases.enumerated() {
            XCTAssertThrowsError(try parse(bytes), "case \(index)")
        }
    }

    func testMetadataEntryWithNonLengthDelimitedFieldsIsSkipped() throws {
        // Inside a StringStringEntryProto, a varint field (wire 0) must
        // be skipped, not fail the entry.
        var entryBytes = Self.varint(3 << 3 | 0) + Self.varint(42) // unknown varint field 3
        entryBytes += Self.entry("k", "v")
        var bytes: [UInt8] = [0x08, 0x08]
        bytes += Self.field(7, [0x2A])
        bytes += Self.field(14, entryBytes)
        XCTAssertEqual(try parse(bytes).metadata, ["k": "v"])
    }
}
