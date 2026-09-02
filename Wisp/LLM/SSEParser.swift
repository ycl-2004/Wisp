import Foundation

/// 解析 OpenAI 风格的 SSE 行，取出 choices[0].delta.content。
enum SSEParser {
    enum Event {
        case delta(String)
        case done
        case ignored
    }

    static func parse(line: String) -> Event {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .ignored }
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        // 有的网关会把错误塞进流里。
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return .delta(String(localized: "\n\n[服务端错误] \(message)"))
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else { return .ignored }
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                return .delta(content)
            }
            // 少数网关把内容包成数组。
            if let parts = delta["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return .delta(text) }
            }
        }
        // 非流式回退。
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return .delta(content)
        }
        return .ignored
    }

    /// 从非流式错误响应里挖出可读信息。
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
            if let message = object["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? String(localized: "服务端没有返回说明。") : String(raw.prefix(400))
    }
}
