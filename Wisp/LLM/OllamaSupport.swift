import Foundation

/// Ollama 走的还是 OpenAI 兼容那条路，这里只补两件 HTTP 之外的事：
/// 服务在不在、装了哪些模型。
enum OllamaSupport {

    static let defaultBaseURL = "http://localhost:11434/v1"

    enum Status {
        case running(models: [String])
        case notRunning
        case failed(String)
    }

    static func probe(baseURL: String) async -> Status {
        guard let url = OpenAICompatibleProvider.endpoint(baseURL, path: "models") else {
            return .failed(String(localized: "Base URL 格式不对"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let session = URLSession(configuration: OpenAICompatibleProvider.privateSessionConfiguration(),
                                     delegate: PrivateAPIRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await OpenAICompatibleProvider.cappedData(
                for: request, session: session, limit: OpenAICompatibleProvider.maxSmallResponseBytes)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(String(localized: "服务有响应但返回异常"))
            }
            guard let models = models(from: data) else {
                return .failed(String(localized: "服务有响应，但返回内容无法识别"))
            }
            return .running(models: models)
        } catch let error as URLError
            where error.code == .cannotConnectToHost || error.code == .networkConnectionLost
               || error.code == .timedOut {
            return .notRunning
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 解析 /v1/models 的响应体。形状不对（不是字典、没有 data 数组、
    /// 根本不是 JSON）返回 nil，让 probe 报 failed：以前一串可选转换以
    /// ?? [] 收尾，坏掉的服务会被说成「运行中、零个模型」（#50）。
    /// data 为空数组是真·零模型，正常返回 []。
    static func models(from data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// 常见安装位置。GUI 应用拿不到登录 shell 的 PATH，只能自己找。
    static let searchPaths = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    static var executablePath: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 后台拉起 `ollama serve`。用户点按钮才会调用。
    static func startServer() -> Bool {
        guard let path = executablePath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// 名字里带这些字样的多半不是视觉模型，界面上给个提醒。
    static func looksLikeVisionModel(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.contains("embed") { return false }
        let hints = ["v4", "vl", "vision", "llava", "minicpm-v", "bakllava", "moondream", "gemma3", "gemma-3"]
        return hints.contains { lowered.contains($0) }
    }
}
