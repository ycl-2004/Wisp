import Foundation

/// 只用 OpenAI-compatible 接口最通用的子集：chat/completions + stream + image_url(data URL)。
/// 不发 tools、不发 detail，最大化各家网关的兼容性。
struct OpenAICompatibleProvider: ChatProvider {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: - 请求构造

    static func endpoint(_ baseURL: String, path: String = "chat/completions") -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/" + path),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private func request(config: ProviderConfig, body: [String: Any]) throws -> URLRequest {
        guard let url = Self.endpoint(config.baseURL) else { throw ProviderError.badBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Wisp/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - 流式

    func stream(messages: [[String: Any]], config: ProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": config.model,
                        "messages": messages,
                        "stream": true,
                    ]
                    let urlRequest = try request(config: config, body: body)
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.network("没有收到 HTTP 响应。")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.mapError(status: http.statusCode, data: data, response: http)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        switch SSEParser.parse(line: line) {
                        case .delta(let text): continuation.yield(text)
                        case .done: continuation.finish(); return
                        case .ignored: continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as URLError
                    where config.kind == .ollama
                        && (error.code == .cannotConnectToHost || error.code == .timedOut) {
                    continuation.finish(throwing: ProviderError.ollamaNotRunning)
                } catch {
                    continuation.finish(throwing: ProviderError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 测试连接

    func validate(config: ProviderConfig) async throws {
        if config.kind.needsAPIKey, config.apiKey.isEmpty { throw ProviderError.missingKey }
        guard let jpeg = ScreenCapturer.tinyTestJPEG() else {
            throw ProviderError.network("无法生成测试图片。")
        }
        let base64 = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 5,
            "stream": false,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "Reply with OK."],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                ],
            ]],
        ]
        let urlRequest = try request(config: config, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError
            where config.kind == .ollama
                && (error.code == .cannotConnectToHost || error.code == .timedOut) {
            throw ProviderError.ollamaNotRunning
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("没有收到 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapError(status: http.statusCode, data: data, response: http)
        }
    }

    // MARK: - 错误映射

    static func mapError(status: Int, data: Data, response: HTTPURLResponse? = nil) -> ProviderError {
        let message = SSEParser.errorMessage(from: data)
        if status == 401 || status == 403 { return .unauthorized }
        if status == 429 {
            let raw = (String(data: data, encoding: .utf8) ?? "") + " " + message
            // OpenRouter 用这句话表示是上游供应商拒绝，不是你的账号额度。
            let upstream = raw.lowercased().contains("provider returned error")
                || raw.lowercased().contains("upstream")
            var hint: String?
            if let response {
                let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                var parts: [String] = []
                if let remaining { parts.append("剩余额度 \(remaining)") }
                if let reset, let seconds = Double(reset) {
                    let date = seconds > 1_000_000_000_000
                        ? Date(timeIntervalSince1970: seconds / 1000)
                        : Date(timeIntervalSince1970: seconds)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    parts.append("恢复时间 \(formatter.string(from: date))")
                }
                if !parts.isEmpty { hint = parts.joined(separator: " · ") }
            }
            return .rateLimited(detail: message, upstream: upstream, resetHint: hint)
        }
        let lowered = message.lowercased()
        let imageHints = ["image", "vision", "multimodal", "image_url", "not support", "unsupported"]
        if (status == 400 || status == 415 || status == 422),
           imageHints.contains(where: { lowered.contains($0) }) {
            return .imageUnsupported("服务端说明：\(message)")
        }
        return .http(status, message)
    }
}
