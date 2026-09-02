import AppKit
import Carbon.HIToolbox
import Foundation

/// The built-in Carbon shortcut is the compatibility path. The other modes use
/// raw keyboard events so modifier-only, Fn/Globe, and repeated-key shortcuts
/// can be represented.
enum ShortcutTriggerMode: String, CaseIterable, Identifiable {
    case standard
    case enhancedSingle
    case doubleTap
    case tripleTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return String(localized: "标准组合")
        case .enhancedSingle: return String(localized: "增强单次")
        case .doubleTap: return String(localized: "双击同一键")
        case .tripleTap: return String(localized: "三击同一键")
        }
    }

    var detail: String {
        switch self {
        case .standard:
            return String(localized: "Command、Option、Control 等常规组合")
        case .enhancedSingle:
            return String(localized: "支持 Shift、Globe/Fn 和单独的修饰键")
        case .doubleTap:
            return String(localized: "连续按两次同一个键，例如 Control")
        case .tripleTap:
            return String(localized: "连续按三次同一个键")
        }
    }

    var tapCount: Int? {
        switch self {
        case .standard: return nil
        case .enhancedSingle: return 1
        case .doubleTap: return 2
        case .tripleTap: return 3
        }
    }
}

struct AdvancedShortcut: Codable, Equatable {
    enum KeyKind: String, Codable {
        case key
        case modifier
    }

    let keyCode: UInt16
    let kind: KeyKind
    /// Modifier flags that must be held for a normal key, including `.function`.
    /// Modifier-only shortcuts leave this at zero because the key itself is the
    /// modifier being tapped.
    let modifiers: UInt

    init(keyCode: UInt16, kind: KeyKind, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.kind = kind
        self.modifiers = modifiers.rawValue
    }

    var eventModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    @MainActor
    var displayName: String {
        let prefix = ShortcutKeyInfo.symbolicRepresentation(for: eventModifiers)
        return prefix + ShortcutKeyInfo.name(for: keyCode, kind: kind)
    }
}

enum ShortcutKeyInfo {
    static let supportedModifiers: NSEvent.ModifierFlags = [
        .capsLock, .shift, .control, .option, .command, .function
    ]

    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch Int(keyCode) {
        case kVK_CapsLock: return .capsLock
        case kVK_Shift, kVK_RightShift: return .shift
        case kVK_Control, kVK_RightControl: return .control
        case kVK_Option, kVK_RightOption: return .option
        case kVK_Command, kVK_RightCommand: return .command
        case kVK_Function: return .function
        default: return nil
        }
    }

    static func name(for keyCode: UInt16, kind: AdvancedShortcut.KeyKind) -> String {
        if kind == .modifier, let modifier = modifierFlag(for: keyCode) {
            switch modifier {
            case .capsLock: return "Caps Lock"
            case .shift: return "Shift"
            case .control: return "Control"
            case .option: return "Option"
            case .command: return "Command"
            case .function: return "Globe/Fn"
            default: break
            }
        }

        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Escape: return "Escape"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1...kVK_F20: return "F\(Int(keyCode) - kVK_F1 + 1)"
        default: return "Key \(keyCode)"
        }
    }

    static func symbolicRepresentation(for modifiers: NSEvent.ModifierFlags) -> String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        if modifiers.contains(.capsLock) { value += "⇪" }
        if modifiers.contains(.function) { value += "🌐︎" }
        return value
    }
}

/// Observes raw key releases in the current app and in other apps. It deliberately
/// does not consume events, so normal text input and the existing Carbon shortcut
/// continue to behave normally.
@MainActor
final class AdvancedShortcutMonitor {
    static let shared = AdvancedShortcutMonitor()

    private struct Candidate: Equatable {
        let keyCode: UInt16
        let kind: AdvancedShortcut.KeyKind
        let modifiers: UInt

        init(_ shortcut: AdvancedShortcut) {
            keyCode = shortcut.keyCode
            kind = shortcut.kind
            modifiers = shortcut.modifiers
        }
    }

    private let tapInterval: TimeInterval = 0.45
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isStarted = false
    private var onMatch: (() -> Void)?

    private var lastCandidate: Candidate?
    private var lastTapDate: Date?
    private var tapCount = 0

    private var recordingTapCount: Int?
    private var recordingCandidate: Candidate?
    private var recordingProgress: ((Int) -> Void)?
    private var recordingCompletion: ((AdvancedShortcut) -> Void)?
    private var recordingGeneration = 0

    private init() {}

    func start() {
        guard !isStarted else { return }

        let eventMask: NSEvent.EventTypeMask = [.keyUp, .flagsChanged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        isStarted = true
    }

    func configure(onMatch: @escaping () -> Void) {
        start()
        self.onMatch = onMatch
    }

    func beginRecording(
        tapCount: Int,
        onProgress: @escaping (Int) -> Void,
        onComplete: @escaping (AdvancedShortcut) -> Void
    ) {
        start()
        cancelRecording()
        recordingTapCount = tapCount
        recordingProgress = onProgress
        recordingCompletion = onComplete
        recordingGeneration += 1
        resetTapSequence()
    }

    func cancelRecording() {
        recordingTapCount = nil
        recordingCandidate = nil
        recordingProgress = nil
        recordingCompletion = nil
        recordingGeneration += 1
        resetTapSequence()
    }

    private func handle(_ event: NSEvent) {
        guard let candidate = candidate(for: event) else { return }

        if recordingTapCount != nil {
            handleRecording(candidate)
            return
        }

        guard
            let targetTapCount = AppSettings.shared.shortcutTrigger.tapCount,
            let configuredShortcut = AppSettings.shared.advancedShortcut,
            Candidate(configuredShortcut) == candidate
        else {
            resetTapSequence()
            return
        }

        let now = Date()
        if lastCandidate == candidate,
           let lastTapDate,
           now.timeIntervalSince(lastTapDate) <= tapInterval {
            tapCount += 1
        } else {
            tapCount = 1
        }
        lastCandidate = candidate
        lastTapDate = now

        if tapCount >= targetTapCount {
            resetTapSequence()
            onMatch?()
        }
    }

    private func handleRecording(_ candidate: Candidate) {
        guard let targetTapCount = recordingTapCount else { return }

        if recordingCandidate == candidate,
           let lastTapDate,
           Date().timeIntervalSince(lastTapDate) <= tapInterval {
            tapCount += 1
        } else {
            recordingCandidate = candidate
            tapCount = 1
        }
        lastCandidate = candidate
        lastTapDate = Date()
        recordingProgress?(tapCount)

        guard tapCount >= targetTapCount else {
            scheduleRecordingReset()
            return
        }

        let shortcut = AdvancedShortcut(
            keyCode: candidate.keyCode,
            kind: candidate.kind,
            modifiers: NSEvent.ModifierFlags(rawValue: candidate.modifiers)
        )
        let completion = recordingCompletion
        cancelRecording()
        completion?(shortcut)
    }

    private func scheduleRecordingReset() {
        recordingGeneration += 1
        let generation = recordingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.recordingGeneration == generation else { return }
                self.recordingCandidate = nil
                self.lastCandidate = nil
                self.lastTapDate = nil
                self.tapCount = 0
                self.recordingProgress?(0)
            }
        }
    }

    private func resetTapSequence() {
        lastCandidate = nil
        lastTapDate = nil
        tapCount = 0
        recordingCandidate = nil
    }

    private func candidate(for event: NSEvent) -> Candidate? {
        switch event.type {
        case .flagsChanged:
            guard
                let modifier = ShortcutKeyInfo.modifierFlag(for: event.keyCode),
                !event.modifierFlags.contains(modifier)
            else {
                return nil
            }
            return Candidate(AdvancedShortcut(keyCode: event.keyCode, kind: .modifier))

        case .keyUp:
            guard ShortcutKeyInfo.modifierFlag(for: event.keyCode) == nil else {
                return nil
            }
            let modifiers = event.modifierFlags.intersection(ShortcutKeyInfo.supportedModifiers)
            return Candidate(AdvancedShortcut(keyCode: event.keyCode, kind: .key, modifiers: modifiers))

        default:
            return nil
        }
    }
}

@MainActor
final class AdvancedShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var progress = 0

    func begin(tapCount: Int, onComplete: @escaping (AdvancedShortcut) -> Void) {
        isRecording = true
        progress = 0
        AdvancedShortcutMonitor.shared.beginRecording(
            tapCount: tapCount,
            onProgress: { [weak self] progress in
                self?.progress = progress
            },
            onComplete: { [weak self] shortcut in
                self?.isRecording = false
                self?.progress = 0
                onComplete(shortcut)
            }
        )
    }

    func cancel() {
        AdvancedShortcutMonitor.shared.cancelRecording()
        isRecording = false
        progress = 0
    }
}
