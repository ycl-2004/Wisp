import AppKit
import ApplicationServices
import CoreGraphics

/// 往目标窗口注入**真实**的系统级滚轮事件。
///
/// 为什么必须走这条路：飞书文档这类应用的虚拟列表只认可信输入。实测在飞书 docx 上，
/// 用 JS 把滚动容器的 `scrollTop` 从 0 推到 3726，已渲染行数**始终是 12 行**、正文
/// 始终 541 字；合成的 `WheelEvent` 同样无效（Chrome 视其为不可信）。而经由
/// `CGEvent` + `.cghidEventTap` 注入后，同一篇文档 6 次滚动就让渲染行数 10 → 14、
/// 正文 697 → 1227 字，完整采集能一路走到文末。
///
/// 代价：需要「辅助功能」权限，并且会短暂借用一下鼠标指针（结束后原位放回）。
/// 所以这条路径由 `AppSettings.captureMode` 显式控制，默认不开。
enum ScrollDriver {

    /// 有没有辅助功能权限。没有就发不出可信事件，只能退回 JS 滚动。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹一次系统的授权提示（已拒绝过则不会再弹，需去系统设置）。
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 取该进程最大的那个在屏窗口。用来算注入事件的坐标。
    static func frontWindowRect(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: CGRect?
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 300, rect.height > 300 else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height {
                best = rect
            }
        }
        return best
    }

    /// 正文大致落在窗口水平居中、垂直 55% 的位置。避开顶部工具栏和底部状态栏，
    /// 也避开左侧目录树——滚轮事件是按指针位置命中的，落错地方会滚到侧边栏上。
    static func contentPoint(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.55)
    }

    /// 采集期间把指针停在目标点，收尾时放回原处。
    ///
    /// 滚轮事件按指针所在窗口派发，所以必须真的把指针移过去；但**不**需要把目标
    /// 应用切到前台，这样用户的焦点不会被抢走。
    static func withCursorParked<T>(at point: CGPoint, _ body: () -> T) -> T {
        let saved = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(point)
        // 让窗口服务器认下新的指针位置再开始发事件。
        usleep(120_000)
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
        }
        return body()
    }

    /// 注入一次滚轮事件。`pixels` 为负表示向下滚。
    static func scroll(pixels: Int32, at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    /// 把页面滚回顶部：连续注入向上的大步长滚动。
    /// 虚拟列表没有可靠的「跳到顶」接口，只能一路滚回去。
    static func scrollToTop(at point: CGPoint, steps: Int = 40) {
        for _ in 0..<steps {
            scroll(pixels: 2_000, at: point)
            usleep(12_000)
        }
    }

    /// 把页面还原到采集开始时用户所在的位置。
    ///
    /// 不能只滚回顶部就完事：用户很可能本来正读到文档中段，采集完把人扔回开头
    /// 是很讨嫌的。这里先一路滚到顶拿一个确定的基准，再往下滚回原来的偏移量。
    /// 虚拟列表的 `scrollTop` 是可读的，所以这个偏移量是可信的。
    static func restore(toScrollTop originalTop: Double, at point: CGPoint) {
        scrollToTop(at: point)
        guard originalTop > 20 else { return }
        var remaining = originalTop
        while remaining > 0 {
            // 最后一步按剩余量精确补齐，别用固定步长冲过头：
            // 固定 600px 时实测会多滚 480px，差不多大半屏。
            let step = Int32(min(600, remaining))
            scroll(pixels: -step, at: point)
            remaining -= Double(step)
            usleep(12_000)
        }
    }
}
