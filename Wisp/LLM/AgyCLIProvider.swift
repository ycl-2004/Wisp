import AppKit
import Darwin
import Foundation

/// 走本地 `agy`。AGY 自己负责登录、模型额度和会话；Wisp 只调用它的 CLI，
/// 所以这里属于「Agent CLI」分组，而不是云端 API。
struct AgyCLIProvider: ChatProvider {
    /// 这是故意比普通网络请求长：AGY 首次启动会扫描本地配置和 skills。
    static let wallClockTimeout: TimeInterval = 300

    /// GUI 应用拿不到登录 shell 的 PATH，常见安装位置都要主动扫。
    /// `~/.local/bin/agy` 是当前安装位置；如果 AGY 更新原地替换它，下一次扫描自然拿到新版本。
    static let searchPaths = [
        NSHomeDirectory() + "/.local/bin/agy",
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
    ]

    private static var candidatePaths: [String] {
        var paths = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/agy" }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// 只检查路径，不缓存版本号。这样 AGY 更新后不需要重置 Wisp 设置。
    static var detectedPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func resolvePath(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        return detectedPath
    }

    /// 多个安装位置同时存在时，实际读取每个候选的版本并选最新的那个。
    /// 不缓存结果，AGY 原地升级或切换安装位置后下一次请求就会重新判断。
    static func latestDetectedPath() async -> String? {
        let candidates = candidatePaths.filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard candidates.count > 1 else { return candidates.first }

        let versions = await withTaskGroup(of: (String, [Int]?).self, returning: [(String, [Int]?)].self) { group in
            for path in candidates {
                group.addTask { (path, await versionNumbers(at: path)) }
            }
            var values: [(String, [Int]?)] = []
            for await value in group { values.append(value) }
            return values
        }

        var best = versions.first!
        for candidate in versions.dropFirst() {
            guard let version = candidate.1 else { continue }
            if best.1 == nil || isNewer(version, than: best.1!) {
                best = candidate
            }
        }
        return best.0
    }

    /// 每次扫描都重新执行 `agy models`，不把模型列表写死在 App 里。
    static func scanModels(configuredPath: String = "") async -> [ModelCatalog.Preset] {
        guard let binary = await pathForUse(configuredPath) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["models"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            return []
        }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { return [] }
        return parseModels(text)
    }

    /// 没有成功扫描时仅用于 UI 首屏，真实请求仍然允许用户手填任意新模型名。
    /// 下一次「刷新 AGY 模型」会以 CLI 的实际输出覆盖它。
    static let fallbackModels: [ModelCatalog.Preset] = [
        .init(slug: "gemini-3.8-flash-high", title: "Gemini 3.8 Flash (High)", note: ""),
        .init(slug: "gemini-3.8-flash-medium", title: "Gemini 3.8 Flash (Medium)", note: ""),
        .init(slug: "gemini-3.8-flash-low", title: "Gemini 3.8 Flash (Low)", note: ""),
        .init(slug: "gemini-3.7-flash-high", title: "Gemini 3.7 Flash (High)", note: ""),
        .init(slug: "gemini-3.7-flash-medium", title: "Gemini 3.7 Flash (Medium)", note: ""),
        .init(slug: "gemini-3.7-flash-low", title: "Gemini 3.7 Flash (Low)", note: ""),
        .init(slug: "gemini-3.6-flash-high", title: "Gemini 3.6 Flash (High)", note: ""),
        .init(slug: "gemini-3.6-flash-medium", title: "Gemini 3.6 Flash (Medium)", note: ""),
        .init(slug: "gemini-3.6-flash-low", title: "Gemini 3.6 Flash (Low)", note: ""),
        .init(slug: "gemini-3.1-pro-high", title: "Gemini 3.1 Pro (High)", note: ""),
        .init(slug: "gemini-3.1-pro-low", title: "Gemini 3.1 Pro (Low)", note: ""),
        .init(slug: "claude-sonnet-4-6", title: "Claude Sonnet 4.6 (Thinking)", note: ""),
        .init(slug: "claude-opus-4-6-thinking", title: "Claude Opus 4.6 (Thinking)", note: ""),
        .init(slug: "gpt-oss-120b-medium", title: "GPT-OSS 120B (Medium)", note: ""),
    ]

    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error> {
        let flattened = CodexCLIProvider.flatten(messages)

        return AsyncThrowingStream { continuation in
            let box = RunBox()
            let work = Task.detached(priority: .userInitiated) {
                do {
                    guard let binary = await Self.pathForUse(config.cliPath) else {
                        throw ProviderError.agyNotFound
                    }

                    let response: String
                    if flattened.images.isEmpty {
                        response = try await Self.runHeadless(prompt: flattened.prompt,
                                                              binary: binary,
                                                              model: config.model,
                                                              box: box)
                    } else {
                        response = try await Self.runInteractive(prompt: flattened.prompt,
                                                                 images: flattened.images,
                                                                 binary: binary,
                                                                 model: config.model,
                                                                 box: box)
                    }
                    continuation.yield(response)
                    continuation.finish()
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: ProviderError.network(error.localizedDescription))
                }
            }

            let watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(Self.wallClockTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                box.stop(.timedOut, onlyIfRunning: true)
            }

            continuation.onTermination = { _ in
                watchdog.cancel()
                box.stop(.cancelled)
                work.cancel()
            }
        }
    }

    func validate(config: ProviderConfig) async throws {
        guard let binary = await Self.pathForUse(config.cliPath) else { throw ProviderError.agyNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw ProviderError.agyTimedOut(15)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ProviderError.agyFailed(Self.condense(detail), status: process.terminationStatus)
        }
    }

    // MARK: - Headless text

    private static func runHeadless(prompt: String,
                                    binary: String,
                                    model: String,
                                    box: RunBox) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = ["-p", prompt, "--output-format", "json", "--print-timeout", "300s", "--sandbox"]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stderrBuffer = DrainBuffer()
        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
        }

        guard box.adopt(process) else { throw ProviderError.cancelled }
        do {
            try process.run()
        } catch {
            stderrHandle.readabilityHandler = nil
            box.finish()
            throw ProviderError.network(error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil
        box.finish()

        if let reason = box.reason {
            throw reason == .timedOut
                ? ProviderError.agyTimedOut(Int(Self.wallClockTimeout))
                : ProviderError.cancelled
        }
        guard process.terminationStatus == 0 else {
            throw ProviderError.agyFailed(Self.condense(stderrBuffer.text), status: process.terminationStatus)
        }
        guard let response = parseResponse(data) else {
            throw ProviderError.agyFailed(Self.condense(stderrBuffer.text), status: process.terminationStatus)
        }
        return response
    }

    // MARK: - Image bridge

    /// AGY 的 headless stream-json 目前拒绝 OpenAI image_url block；交互 TUI 可以从
    /// 剪贴板读取图片，所以有截图时用一个短生命周期的 PTY 桥接。原剪贴板会恢复，
    /// 且只有在用户没有在此期间改动剪贴板时才恢复，避免覆盖用户的新复制内容。
    private static func runInteractive(prompt: String,
                                       images: [Data],
                                       binary: String,
                                       model: String,
                                       box: RunBox) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        var arguments = ["-q", "/dev/null", binary, "--sandbox"]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        process.arguments = arguments

        guard let pty = PTYSession() else {
            throw ProviderError.agyFailed("无法创建 AGY 的 PTY 终端", status: -1)
        }
        process.standardInput = pty.slave
        process.standardOutput = pty.slave
        process.standardError = pty.slave

        let terminal = TerminalBuffer()
        let masterHandle = pty.master
        masterHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                terminal.append(chunk)
            }
        }

        guard box.adopt(process) else { throw ProviderError.cancelled }
        var originalClipboard: PasteboardSnapshot?
        var assignedChangeCount: Int?
        do {
            try process.run()

            // script 和 AGY 都运行在 pty slave 上；写入 master 才等价于用户
            // 在真实终端里打字，输出也从 master 读回。
            try await Task.sleep(nanoseconds: 1_500_000_000)

            for image in images {
                guard let assignment = await installClipboardImage(image) else {
                    throw ProviderError.agyFailed("无法把截图放入剪贴板", status: process.terminationStatus)
                }
                if originalClipboard == nil { originalClipboard = assignment.snapshot }
                assignedChangeCount = assignment.changeCount
                masterHandle.write(Data([0x16])) // Ctrl+V
                try await waitFor(terminal, containing: "media attached", seconds: 10)
            }

            let inputEnding = "WISP_AGY_INPUT_END_\(UUID().uuidString)"
            let request = "\(prompt)\n\n\(inputEnding)"
            masterHandle.write(Data(request.utf8))
            masterHandle.write(Data([0x0D]))

            // This summary is emitted by the TUI only after the model has finished;
            // unlike a token we typed, it cannot be satisfied by input echo.
            try await waitFor(terminal, containing: "Thought for", seconds: Self.wallClockTimeout)
            try await waitForQuiet(terminal, seconds: 5, maximum: Self.wallClockTimeout)
            let responseTranscript = terminal.text
            try? await Task.sleep(nanoseconds: 300_000_000)
            masterHandle.write(Data([0x04])) // Ctrl+D
            try? await Task.sleep(nanoseconds: 200_000_000)
            masterHandle.write(Data([0x04]))

            let exitDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < exitDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()

            pty.closeSlave()
            masterHandle.readabilityHandler = nil
            box.finish()

            if let reason = box.reason {
                throw reason == .timedOut
                    ? ProviderError.agyTimedOut(Int(Self.wallClockTimeout))
                    : ProviderError.cancelled
            }
            guard let answer = extractAnswer(from: responseTranscript, afterInputEnding: inputEnding),
                  !answer.isEmpty else {
                throw ProviderError.agyFailed("AGY 返回了无法解析的终端答案", status: process.terminationStatus)
            }
            if let originalClipboard, let assignedChangeCount {
                await restoreClipboard(originalClipboard, onlyIfChangeCount: assignedChangeCount)
            }
            return answer
        } catch {
            if process.isRunning { process.terminate() }
            pty.closeSlave()
            masterHandle.readabilityHandler = nil
            box.finish()
            if let originalClipboard, let assignedChangeCount {
                await restoreClipboard(originalClipboard, onlyIfChangeCount: assignedChangeCount)
            }
            throw error
        }
    }

    // MARK: - Process and terminal helpers

    private final class PTYSession: @unchecked Sendable {
        let master: FileHandle
        let slave: FileHandle

        init?() {
            var masterFD: Int32 = -1
            var slaveFD: Int32 = -1
            var size = winsize(ws_row: 40, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { return nil }
            master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
            slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        }

        func closeSlave() {
            try? slave.close()
        }
    }

    private final class RunBox: @unchecked Sendable {
        enum Stop { case cancelled, timedOut }

        private let lock = NSLock()
        private var process: Process?
        private var stopReason: Stop?
        private var settled = false

        func adopt(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { return false }
            self.process = process
            return true
        }

        func stop(_ reason: Stop, onlyIfRunning: Bool = false) {
            lock.lock()
            guard !settled else { lock.unlock(); return }
            if onlyIfRunning, process?.isRunning != true { lock.unlock(); return }
            stopReason = reason
            let target = process
            settled = true
            process = nil
            lock.unlock()

            guard let target, target.isRunning else { return }
            target.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if target.isRunning { kill(target.processIdentifier, SIGKILL) }
            }
        }

        func finish() {
            lock.lock(); settled = true; process = nil; lock.unlock()
        }

        var reason: Stop? {
            lock.lock(); defer { lock.unlock() }
            return stopReason
        }
    }

    private final class DrainBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private final class TerminalBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func waitFor(_ terminal: TerminalBuffer,
                                containing marker: String,
                                seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if terminal.text.localizedCaseInsensitiveContains(marker) { return }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProviderError.agyFailed("等待 AGY 终端响应超时（\(marker)）", status: -1)
    }

    private static func waitForQuiet(_ terminal: TerminalBuffer,
                                     seconds: TimeInterval,
                                     maximum: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(maximum)
        var lastLength = terminal.text.utf8.count
        var lastChange = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            let length = terminal.text.utf8.count
            if length != lastLength {
                lastLength = length
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) >= seconds {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProviderError.agyFailed("AGY 生成后没有进入稳定状态", status: -1)
    }

    private static func pathForUse(_ configured: String) async -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        return await latestDetectedPath() ?? detectedPath
    }

    private static func versionNumbers(at path: String) async -> [Int]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let match = text.range(of: "[0-9]+(?:\\.[0-9]+)+", options: .regularExpression) else {
            return nil
        }
        return text[match].split(separator: ".").compactMap { Int($0) }
    }

    private static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        let count = max(candidate.count, current.count)
        for index in 0..<count {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private struct PasteboardSnapshot: @unchecked Sendable {
        let items: [[String: Data]]
    }

    private struct ClipboardAssignment: @unchecked Sendable {
        let snapshot: PasteboardSnapshot
        let changeCount: Int
    }

    private static func installClipboardImage(_ data: Data) async -> ClipboardAssignment? {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(items: pasteboard.pasteboardItems?.map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type.rawValue, data)
                })
            } ?? [])

            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            let item = NSPasteboardItem()
            item.setData(png, forType: NSPasteboard.PasteboardType(rawValue: "public.png"))
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return ClipboardAssignment(snapshot: snapshot, changeCount: pasteboard.changeCount)
        }
    }

    private static func restoreClipboard(_ snapshot: PasteboardSnapshot,
                                         onlyIfChangeCount changeCount: Int) async {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount else { return }
            let items = snapshot.items.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (rawType, data) in values {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: rawType))
                }
                return item
            }
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private static func parseModels(_ text: String) -> [ModelCatalog.Preset] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let slugPart = parts.first else { return nil }
            let slug = String(slugPart)
            guard slug.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                  seen.insert(slug).inserted else { return nil }
            let title = parts.count > 1 ? String(parts[1]) : slug
            return ModelCatalog.Preset(slug: slug, title: title, note: "")
        }
    }

    private static func parseResponse(_ data: Data) -> String? {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let text: String
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") {
            text = String(raw[start...end])
        } else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (object["status"] as? String) == "SUCCESS" else { return nil }
        return (object["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractAnswer(from raw: String, afterInputEnding inputEnding: String) -> String? {
        guard raw.contains(inputEnding) else { return nil }
        let lines = renderTerminal(raw)
        guard let thoughtIndex = lines.firstIndex(where: { $0.contains("Thought for") }) else { return nil }

        var answerLines: [String] = []
        for rawLine in lines.dropFirst(thoughtIndex + 1) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == ">" || line.hasPrefix("press ctrl+d") || line.hasPrefix("Resume with -c") { break }
            if line.allSatisfy({ $0 == "─" || $0 == "-" }) && line.count >= 10 { break }
            guard !line.isEmpty,
                  !line.contains("tokens"),
                  !line.contains("? for shortcuts"),
                  !line.hasPrefix("▸"),
                  !line.hasPrefix("⣷"),
                  !line.hasPrefix("⣻"),
                  !line.hasPrefix("⡿"),
                  !line.hasPrefix("⢿"),
                  !line.hasPrefix("⣯") else { continue }

            if line.hasPrefix("The image"),
               let previous = answerLines.lastIndex(where: { $0.hasPrefix("The image") }) {
                // The vision model may print an early summary before the final
                // answer. The last, non-ellipsized redraw is the useful one.
                if !line.contains("...") || answerLines[previous].contains("...") {
                    answerLines[previous] = line
                }
                continue
            }
            answerLines.append(line)
        }
        return answerLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 AGY TUI 的 ANSI 光标移动／擦除重放到一个小型终端画布里。直接处理
    /// transcript 会把重绘中的半行混进答案；画布状态才是用户实际看到的内容。
    private static func renderTerminal(_ raw: String) -> [String] {
        let rows = 40
        let columns = 140
        var screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        var row = 0
        var column = 0
        var savedRow = 0
        var savedColumn = 0
        var lastCharacter = " "

        func clampRow(_ value: Int) -> Int { min(max(value, 0), rows - 1) }
        func clampColumn(_ value: Int) -> Int { min(max(value, 0), columns - 1) }

        func scrollIfNeeded() {
            while row >= rows {
                screen.removeFirst()
                screen.append(Array(repeating: " ", count: columns))
                row -= 1
            }
        }

        func write(_ character: String, width: Int) {
            guard !character.isEmpty else { return }
            if column >= columns {
                column = 0
                row += 1
                scrollIfNeeded()
            }
            screen[row][column] = character
            lastCharacter = character
            column += max(width, 1)
            if column >= columns {
                column = 0
                row += 1
                scrollIfNeeded()
            }
        }

        func eraseCharacters(_ count: Int) {
            guard row >= 0, row < rows else { return }
            for offset in 0..<max(count, 1) where column + offset < columns {
                screen[row][column + offset] = " "
            }
        }

        func eraseLine(mode: Int) {
            guard row >= 0, row < rows else { return }
            let start: Int
            let end: Int
            switch mode {
            case 1:
                start = 0; end = clampColumn(column)
            case 2:
                start = 0; end = columns - 1
            default:
                start = clampColumn(column); end = columns - 1
            }
            if start <= end {
                for index in start...end { screen[row][index] = " " }
            }
        }

        func eraseDisplay(mode: Int) {
            switch mode {
            case 2, 3:
                screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
            default:
                eraseLine(mode: 0)
                if row + 1 < rows {
                    for line in (row + 1)..<rows {
                        screen[line] = Array(repeating: " ", count: columns)
                    }
                }
            }
        }

        func parameter(_ params: [Int], _ index: Int, default value: Int) -> Int {
            guard index < params.count, params[index] != 0 else { return value }
            return params[index]
        }

        func displayWidth(_ scalar: UnicodeScalar) -> Int {
            switch scalar.value {
            case 0x0300...0x036F, 0xFE00...0xFE0F:
                return 0
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
                 0xF900...0xFAFF, 0xFE10...0xFE6F, 0xFF00...0xFF60,
                 0x1F300...0x1FAFF:
                return 2
            default:
                return 1
            }
        }

        let scalars = Array(raw.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let next = scalars[index + 1]
                if next.value == 0x5B { // CSI
                    var end = index + 2
                    while end < scalars.count && !(0x40...0x7E).contains(scalars[end].value) { end += 1 }
                    guard end < scalars.count else { break }
                    let final = scalars[end]
                    let parameterText = String(String.UnicodeScalarView(scalars[(index + 2)..<end]))
                    let privatePrefix = parameterText.first == "?"
                    let numbers = parameterText
                        .filter { $0.isNumber || $0 == ";" }
                        .split(separator: ";")
                        .map { Int($0) ?? 0 }
                    if !privatePrefix {
                        switch final.value {
                        case 0x41: row = clampRow(row - parameter(numbers, 0, default: 1))
                        case 0x42: row = clampRow(row + parameter(numbers, 0, default: 1))
                        case 0x43: column = clampColumn(column + parameter(numbers, 0, default: 1))
                        case 0x44: column = clampColumn(column - parameter(numbers, 0, default: 1))
                        case 0x45: row = clampRow(row + parameter(numbers, 0, default: 1)); column = 0
                        case 0x46: row = clampRow(row - parameter(numbers, 0, default: 1)); column = 0
                        case 0x47: column = clampColumn(parameter(numbers, 0, default: 1) - 1)
                        case 0x48, 0x66:
                            row = clampRow(parameter(numbers, 0, default: 1) - 1)
                            column = clampColumn(parameter(numbers, 1, default: 1) - 1)
                        case 0x4A: eraseDisplay(mode: parameter(numbers, 0, default: 0))
                        case 0x4B: eraseLine(mode: parameter(numbers, 0, default: 0))
                        case 0x4D, 0x50: eraseCharacters(parameter(numbers, 0, default: 1))
                        case 0x58: eraseCharacters(parameter(numbers, 0, default: 1))
                        case 0x62:
                            for _ in 0..<parameter(numbers, 0, default: 1) { write(lastCharacter, width: 1) }
                        default: break
                        }
                    }
                    index = end + 1
                    continue
                }
                if next.value == 0x5D { // OSC
                    var end = index + 2
                    while end < scalars.count && scalars[end].value != 0x07 {
                        if scalars[end].value == 0x1B, end + 1 < scalars.count, scalars[end + 1].value == 0x5C {
                            end += 1
                            break
                        }
                        end += 1
                    }
                    index = min(end + 1, scalars.count)
                    continue
                }
                if next.value == 0x37 { savedRow = row; savedColumn = column }
                if next.value == 0x38 { row = savedRow; column = savedColumn }
                index += 2
                continue
            }

            switch scalar.value {
            case 0x0D: column = 0
            case 0x0A:
                row += 1
                scrollIfNeeded()
            case 0x08: column = max(0, column - 1)
            case 0x09: column = min(columns - 1, ((column / 8) + 1) * 8)
            case 0x07: break
            case 0x20...0x10FFFF:
                write(String(scalar), width: displayWidth(scalar))
            default: break
            }
            index += 1
        }
        return screen.map { $0.joined() }
    }

    private static func condense(_ text: String) -> String {
        let meaningful = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(meaningful.suffix(4).joined(separator: "\n").prefix(400))
    }
}
