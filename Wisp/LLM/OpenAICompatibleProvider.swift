import Foundation

/// Keep captured content at the exact configured API destination. A redirect must
/// be configured explicitly by the user, rather than forwarding a private POST.
final class PrivateAPIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// 只用 OpenAI-compatible 接口最通用的子集：chat/completions + stream + image_url(data URL)。
/// 不发 tools、不发 detail，最大化各家网关的兼容性。
struct OpenAICompatibleProvider: ChatProvider {

    private let session: URLSession

    /// 多久没有任何新数据就判定这条流断了。流式回答里它是「静默上限」，不是总时长上限。
    static let idleTimeout: TimeInterval = 60

    /// 非 2xx 时最多读多少错误响应体。真正的错误 JSON 只有几百字节，
    /// `mapError` 用到的信息都在开头；上限之外读进来也只是白占内存。
    static let maxErrorBodyBytes = 64 * 1024

    init(configuration: URLSessionConfiguration = OpenAICompatibleProvider.privateSessionConfiguration()) {
        let config = configuration
        config.timeoutIntervalForRequest = Self.idleTimeout
        config.timeoutIntervalForResource = 300
        // 关掉它。开着的话断网不会报错，而是最多干等 timeoutIntervalForResource（5 分钟），
        // 期间界面一直显示「生成中」且没有任何提示。宁可立刻失败。
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: PrivateAPIRedirectPolicy(), delegateQueue: nil)
    }

    // No disk cache, cookie jar, or stored HTTP credentials for captured content.
    // https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral
    static func privateSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    // MARK: - 请求构造

    static func endpoint(_ baseURL: String, path: String = "chat/completions") -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/" + path),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        // Local Ollama remains usable; remote prompts and keys require TLS.
        if url.scheme == "http", !["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) {
            return nil
        }
        return url
    }

    private func request(config: ProviderConfig, body: [String: Any], allowPriority: Bool = true) throws -> URLRequest {
        guard let url = Self.endpoint(config.baseURL) else { throw ProviderError.badBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Wisp/0.1", forHTTPHeaderField: "User-Agent")
        var payload = ResponsePolicy.applying(config.responseMode, to: Self.speedPreferredBody(body, endpoint: url), endpoint: url)
        if !allowPriority { payload.removeValue(forKey: "service_tier") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Apply only documented first-party API options; custom gateways stay compatible.
    /// https://openrouter.ai/docs/guides/features/service-tiers
    /// https://openrouter.ai/docs/guides/routing/provider-selection
    /// https://developers.openai.com/api/docs/guides/fast-mode
    /// https://ai.google.dev/gemini-api/docs/openai#flex-and-priority-inference
    static func speedPreferredBody(_ body: [String: Any], endpoint: URL) -> [String: Any] {
        var result = body
        switch (endpoint.host?.lowercased(), endpoint.path) {
        case ("openrouter.ai", "/api/v1/chat/completions"):
            result["provider"] = ["sort": "throughput", "allow_fallbacks": true] as [String: Any]
            // Keep free model IDs and their free-only routing. Never switch models for speed.
            let model = body["model"] as? String ?? ""
            if !model.split(separator: ":").contains("free") {
                result["service_tier"] = "priority"
            }
        case ("api.openai.com", "/v1/chat/completions"),
             ("generativelanguage.googleapis.com", "/v1beta/openai/chat/completions"):
            result["service_tier"] = "priority"
        default:
            break
        }
        return result
    }

    /// Retry only explicit tier rejection before receiving any answer, never auth,
    /// rate limits, transport failures or unrelated model/capability errors.
    static func rejectsPriority(status: Int, data: Data, request: URLRequest) -> Bool {
        guard [400, 403, 422].contains(status),
              let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload["service_tier"] as? String == "priority" else { return false }
        let message = SSEParser.errorMessage(from: data).lowercased()
        let identifiesTier = message.contains("service_tier") || message.contains("service tier")
            || message.contains("priority tier") || message.contains("priority processing")
        let rejectsTier = ["not supported", "unsupported", "not available", "unavailable",
                           "not allowed", "not enabled", "not eligible", "invalid", "not permitted"]
            .contains { message.contains($0) }
        return identifiesTier && rejectsTier
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
                    var allowPriority = true
                    while true {
                        try Task.checkCancellation()
                        let urlRequest = try request(config: config, body: body, allowPriority: allowPriority)
                        let (bytes, response) = try await session.bytes(for: urlRequest)

                        guard let http = response as? HTTPURLResponse else {
                            throw ProviderError.network(String(localized: "没有收到 HTTP 响应。"))
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            // 错误体只收前 64 KiB：抽风的服务端可以无限吐，
                            // 但状态码和错误 JSON 的开头已经足够 mapError 判断了。
                            var errorBody = CappedDataBuffer(limit: Self.maxErrorBodyBytes)
                            for try await byte in bytes {
                                if !errorBody.append(byte) { break }
                            }
                            let data = errorBody.data
                            if Self.rejectsPriority(status: http.statusCode, data: data, request: urlRequest) {
                                allowPriority = false
                                continue
                            }
                            throw Self.mapError(status: http.statusCode, data: data, response: http)
                        }

                        // 不用 `bytes.lines`：它把整行攒齐才交出来，单行没有
                        // 上限。改走有上限的 SSELineSplitter，超长行直接报错。
                        var splitter = SSELineSplitter()
                        var sawDone = false
                        for try await byte in bytes {
                            if Task.isCancelled { break }
                            guard let line = try splitter.feed(byte) else { continue }
                            switch SSEParser.parse(line: line) {
                            case .delta(let text): continuation.yield(text)
                            case .done: sawDone = true
                            case .ignored: continue
                            }
                            if sawDone { break }
                        }
                        // 没等到 [DONE] 就断流时，最后一行往往没有换行结尾，
                        // 和 `bytes.lines` 一样把残行也交出去，别丢掉收尾的增量。
                        if !sawDone, !Task.isCancelled, let line = splitter.finish(),
                           case .delta(let text) = SSEParser.parse(line: line) {
                            continuation.yield(text)
                        }
                        try Task.checkCancellation()
                        continuation.finish()
                        return
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch is SSELineSplitter.Failure {
                    continuation.finish(throwing: ProviderError.network(String(localized: "服务端返回的单行数据过长，已中断。")))
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: Self.mapTransport(error, kind: config.kind))
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
            throw ProviderError.network(String(localized: "无法生成测试图片。"))
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
        var allowPriority = true
        while true {
            try Task.checkCancellation()
            let urlRequest = try request(config: config, body: body, allowPriority: allowPriority)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch let error as URLError {
                throw Self.mapTransport(error, kind: config.kind)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network(String(localized: "没有收到 HTTP 响应。"))
            }
            guard (200..<300).contains(http.statusCode) else {
                if Self.rejectsPriority(status: http.statusCode, data: data, request: urlRequest) {
                    allowPriority = false
                    continue
                }
                throw Self.mapError(status: http.statusCode, data: data, response: http)
            }
            return
        }
    }

    // MARK: - 错误映射

    /// 传输层错误统一在这里翻译，省得每个 catch 各写一套。
    static func mapTransport(_ error: URLError, kind: ProviderKind) -> ProviderError {
        // 本地 Ollama 连不上，几乎总是因为服务没起来，直接给可操作的提示。
        let localServiceDown: Set<URLError.Code> = [
            .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
        ]
        if kind == .ollama, localServiceDown.contains(error.code) {
            return .ollamaNotRunning
        }
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut(Int(idleTimeout))
        case .cannotFindHost, .dnsLookupFailed:
            return .network(String(localized: "找不到这个域名。检查 Base URL 拼写是否正确。"))
        case .cannotConnectToHost:
            return .network(String(localized: "连不上这个地址。检查 Base URL 和端口，以及对方服务是否在运行。"))
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return .network(String(localized: "TLS 握手失败。如果是自建网关，检查它的证书。"))
        default:
            return .network(error.localizedDescription)
        }
    }

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
                if let remaining { parts.append(String(localized: "剩余额度 \(remaining)")) }
                if let reset, let seconds = Double(reset) {
                    let date = seconds > 1_000_000_000_000
                        ? Date(timeIntervalSince1970: seconds / 1000)
                        : Date(timeIntervalSince1970: seconds)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    parts.append(String(localized: "恢复时间 \(formatter.string(from: date))"))
                }
                if !parts.isEmpty { hint = parts.joined(separator: " · ") }
            }
            return .rateLimited(detail: message, upstream: upstream, resetHint: hint)
        }
        let lowered = message.lowercased()
        let imageHints = ["image", "vision", "multimodal", "image_url", "not support", "unsupported"]
        if (status == 400 || status == 415 || status == 422),
           imageHints.contains(where: { lowered.contains($0) }) {
            return .imageUnsupported(String(localized: "服务端说明：\(message)"))
        }
        return .http(status, message)
    }
}

/// 有上限的字节累积：喂多少都只留最前面的 `limit` 字节。
///
/// 给「读多少都行、但不能无限读」的数据用（目前是非 2xx 的错误响应体）。
/// 到上限后多余的字节直接丢弃，`append` 返回 false 让调用方停止读取。
struct CappedDataBuffer {
    let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// 喂一个字节。返回 false 表示上限已满（本次字节被丢弃），调用方应停止读取。
    @discardableResult
    mutating func append(_ byte: UInt8) -> Bool {
        guard !truncated else { return false }
        guard data.count < limit else {
            truncated = true
            return false
        }
        data.append(byte)
        return true
    }

    /// 喂一整块。返回 false 表示中途到顶（块的尾巴被丢弃）。
    @discardableResult
    mutating func append(contentsOf chunk: Data) -> Bool {
        for byte in chunk {
            guard append(byte) else { return false }
        }
        return true
    }
}
