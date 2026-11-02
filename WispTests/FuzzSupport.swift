import Foundation

/// Deterministic PRNG for the property/fuzz-style tests (audit round 4,
/// test-engineering lane). SplitMix64: tiny, seedable, no external packages.
/// Every fuzz test in this target seeds it with a fixed constant so a
/// failure reproduces byte-for-byte on any machine and any run.
struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `0..<bound` (bound must be > 0).
    mutating func nextInt(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    /// Uniform integer in a closed range.
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + nextInt(range.count)
    }

    mutating func nextBool() -> Bool { next() & 1 == 0 }

    /// A random byte, biased toward bytes that stress parsers: line
    /// delimiters, the `data:` prefix alphabet, JSON punctuation, and
    /// UTF-8 lead/continuation bytes.
    mutating func nextInterestingByte() -> UInt8 {
        let interesting: [UInt8] = [
            0x0A, 0x0D, 0x00, 0x20, 0x09, 0x3A, 0x22, 0x7B, 0x7D, 0x5B, 0x5D,
            0x64, 0x61, 0x74, 0x2E, 0xC3, 0xA9, 0xE4, 0xBD, 0xA0, 0xF0, 0x9F,
            0x80, 0xFF, 0xFE,
        ]
        if nextInt(3) == 0 { return interesting[nextInt(interesting.count)] }
        return UInt8(next() & 0xFF)
    }

    mutating func nextBytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in nextInterestingByte() }
    }
}
