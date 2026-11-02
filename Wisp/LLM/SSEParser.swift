import Foundation

/// 把字节流切成行，并给单行长度设上限。
///
/// `URLSession.AsyncBytes.lines` 会把一整行攒齐才交出来：服务端如果一直不发
/// 换行（抽风的网关、自建代理都有可能），内存就跟着一直涨，直到 300 秒的
/// resource 超时才停。这里逐字节攒行，超过上限立刻抛错，调用方按网络错误处理。
struct SSELineSplitter {
    /// 真实的 SSE 数据行只有几 KB；1 MiB 给足所有网关的余量，又不至于伤内存。
    static let maxLineBytes = 1 << 20

    enum Failure: Error, Equatable {
        case lineTooLong(limit: Int)
    }

    private var buffer = Data()

    /// 喂一个字节。攒满一行时返回该行（已去掉结尾的 \n 和一个可选的 \r），
    /// 否则返回 nil。单行超过上限时抛 `Failure.lineTooLong`，调用方应中断这条流。
    mutating func feed(_ byte: UInt8) throws -> String? {
        if byte == 0x0A {
            // 有损解码：一个坏字节只坏它自己，不能整行消失（#51）——
            // 严格解码失败会把 "" 交出去，答案里凭空少一段还会被存盘。
            let line = String(decoding: strippedCR(buffer), as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        buffer.append(byte)
        if buffer.count > Self.maxLineBytes {
            throw Failure.lineTooLong(limit: Self.maxLineBytes)
        }
        return nil
    }

    /// 流结束时把没有换行结尾的最后一行交出来（与 `AsyncBytes.lines` 的行为一致）。
    /// 没有残行时返回 nil。
    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = String(decoding: strippedCR(buffer), as: UTF8.self)
        buffer.removeAll()
        return line
    }

    private func strippedCR(_ data: Data) -> Data {
        data.last == 0x0D ? data.dropLast() : data
    }
}

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
