import Foundation

// HARNESS-ONLY shims. Nothing in this file is app code, and no app source
// was edited to accommodate the harness. Each shim exists because the real
// implementation lives behind a macOS-only framework; every one is listed
// in the README with its fidelity limits. The ported tests assert app
// logic, never shim behaviour beyond the documented surface.

#if os(Linux)
/// URLSession & friends live in FoundationNetworking on Linux; app sources
/// import only Foundation (on macOS that suffices). An @_exported import in
/// one file of a module makes the symbols available module-wide.
@_exported import FoundationNetworking
#endif

// MARK: - Combine (absent from Linux Foundation)
//
// On macOS, Foundation re-exports Combine's ObservableObject/@Published,
// which is why app files use them with only `import Foundation`. Linux
// Foundation has neither. These minimal stand-ins let the store/settings
// classes compile and run their logic; change-notification semantics are
// NOT reproduced (objectWillChange is a no-op sink), which is fine for the
// logic tests ported here and is called out in the README.

public protocol ObservableObject: AnyObject {}

public struct ObservableObjectPublisher {
    public init() {}
    public func send() {}
}

public extension ObservableObject {
    var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

// MARK: - String(localized:) (absent from Linux Foundation)
//
// App sources use String(localized:) pervasively. On macOS it resolves the
// string against Localizable.xcstrings; the harness has no catalog, so
// this stand-in returns the source (default) string with interpolations
// applied — the same result a missing key produces on macOS. Logic that
// depends on *which language* comes back is therefore not verified here;
// logic that depends on the string's *content structure* is.

public struct LocalizedStringValue: ExpressibleByStringInterpolation {
    public let string: String
    public init(stringLiteral value: String) { string = value }
    public init(stringInterpolation: StringInterpolation) { string = stringInterpolation.result }

    public struct StringInterpolation: StringInterpolationProtocol {
        var result = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { result += literal }
        public mutating func appendInterpolation<T>(_ value: T) { result += String(describing: value) }
    }
}

public extension String {
    init(localized value: LocalizedStringValue) { self = value.string }
}

// MARK: - KeychainStore (real one uses the Security framework)
//
// Only the surface the compiled closure references. Backed by an in-memory
// dictionary: `ProviderConfig.authorized` behaves exactly as it does with
// an empty Keychain (missingKey) until a test saves a key.

enum KeychainStore {
    private static var storage: [String: String] = [:]

    static func save(_ key: String, for provider: CloudProvider) -> Bool {
        storage[provider.rawValue] = key
        return true
    }

    static func load(for provider: CloudProvider) -> String? {
        storage[provider.rawValue]
    }

    static func delete(for provider: CloudProvider) -> Bool {
        storage.removeValue(forKey: provider.rawValue)
        return true
    }

    static func hasKey(for provider: CloudProvider) -> Bool { load(for: provider) != nil }

    static func deleteAll() { storage.removeAll() }
}

// MARK: - UpdateChecker (real one lives in AppLifecycle.swift, AppKit)
//
// Mirrors the two pure accessors the compiled closure uses, byte-for-byte
// in behaviour: the version comes from the bundle's
// CFBundleShortVersionString with a "0" fallback, and the User-Agent is
// derived from it. (The harness bundle has no such key, so tests see the
// fallback — the derivation wiring is what the ported tests pin.)

enum UpdateChecker {
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var userAgent: String { "Wisp/\(currentVersion)" }
}

// MARK: - ScreenCapturer (real one uses ScreenCaptureKit)
//
// The pure geometry helpers (maxLongEdge / displayIndex) are extracted
// verbatim into ScreenCapturerExtract.swift by the sync. tinyTestJPEG
// needs CoreGraphics/ImageIO, so it stays a stub here: minimal JPEG
// framing bytes; no ported test inspects the image, one test only
// requires it to be non-nil (as on macOS).

extension ScreenCapturer {
    static func tinyTestJPEG() -> Data? {
        Data([0xFF, 0xD8, 0xFF, 0xD9])
    }
}

// MARK: - URLSession.bytes(for:) (absent from Linux Foundation)
//
// The provider's streaming loop consumes `session.bytes(for:)`. Linux
// Foundation has no such API, so the harness supplies one with the same
// shape, backed by a whole-response data task: bytes arrive in one buffer
// rather than incrementally. The provider's own loop — SSE splitting,
// caps, error mapping, the code round 2 actually changed — runs verbatim;
// only the transport's *incrementality* differs, and no ported test
// streams from a live server.

public struct HarnessAsyncBytes: AsyncSequence {
    public typealias Element = UInt8
    let data: Data
    public func makeAsyncIterator() -> Iterator { Iterator(data: data) }
    public struct Iterator: AsyncIteratorProtocol {
        let data: Data
        var index = 0
        public mutating func next() async -> UInt8? {
            guard index < data.count else { return nil }
            defer { index += 1 }
            return data[index]
        }
    }
}

public extension URLSession {
    func bytes(for request: URLRequest) async throws -> (HarnessAsyncBytes, URLResponse) {
        let (data, response) = try await data(for: request)
        return (HarnessAsyncBytes(data: data), response)
    }
}

// MARK: - ScrollDriver (real one uses CGEvent / AppKit)
//
// BrowserTextExtractor's scroll-collection loop drives this. The stub is
// inert and untrusted, so the extractor takes its no-scroll path — the
// parsing/family/error logic under test stays real; only the actuation
// (which needs a live Mac GUI) is absent.

enum ScrollDriver {
    static var isTrusted: Bool { false }
    static func frontWindowRect(pid: pid_t) -> CGRect? { nil }
    static func contentPoint(in rect: CGRect) -> CGPoint { rect.origin }
    static func withCursorParked<T>(at point: CGPoint, _ body: () -> T) -> T { body() }
    static func scroll(pixels: Int32, at point: CGPoint) {}
    static func restore(toScrollTop originalTop: Double, at point: CGPoint) {}
}

// MARK: - Shortcut types (real ones live in AdvancedShortcut.swift, AppKit/Carbon)
//
// AppSettings persists these two opaquely (raw value / JSON blob). The
// stubs mirror the real raw values and Codable fields exactly, so the
// settings round-trip logic under test is real; the key-name/display
// machinery (Carbon tables) is not part of the closure.

enum ShortcutTriggerMode: String, CaseIterable {
    case standard, enhancedSingle, doubleTap, tripleTap
}

struct AdvancedShortcut: Codable, Equatable {
    enum KeyKind: String, Codable {
        case key
        case modifier
    }
    let keyCode: UInt16
    let kind: KeyKind
    let modifiers: UInt
}

// MARK: - LocalSpeechCatalog constant (real class wraps sherpa-onnx)
//
// ListeningTranscript's ListeningEngine migration reads exactly one
// constant from the catalog. The value is mirrored here; sync-sources.sh
// asserts the real file still carries this exact string, so drift fails
// the sync loudly instead of silently testing a stale copy.

enum LocalSpeechCatalog {
    static let legacySenseVoiceID = "k2-fsa/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
}

