import Foundation

/// 注入到浏览器当前分页里的提取脚本。每段都返回一个 JSON 字符串。
///
/// 飞书文档、Notion、Google Docs 这类应用用虚拟滚动：只有可视区域附近的块
/// 真正存在于 DOM 里，一次 `body.innerText` 最多只能拿到一屏，正文会在
/// 屏幕底部那一句戛然而止。所以除了单次提取，这里还提供「多次调用累积」的
/// 滚动采集：`begin` → `step` × N → `finish`。
///
/// 每次调用都是一个独立的 osascript 进程，两次调用之间浏览器有时间重排，
/// 所以 `step` 的顺序刻意是「先收集上一次滚动后新渲染出来的内容，再往下滚」。
/// 采集状态挂在 `window.__wispCollector` 上，同一个分页内跨调用存活。
enum PageTextScript {

    /// 三段脚本共用的工具函数。
    private static let helpers = #"""
      function wClean(s) {
        return String(s || "")
          .replace(/[ \t ​]+/g, " ")
          .replace(/\n[ ]+/g, "\n")
          .replace(/\n{3,}/g, "\n\n")
          .trim();
      }
      // 找真正在滚的那个容器：虚拟滚动应用通常不是让 document 滚，
      // 而是内层某个 overflow-y:auto 的 div。取「可滚距离」最大的那个。
      function wFindScroller() {
        var doc = document.scrollingElement || document.documentElement;
        var best = doc;
        var bestGap = doc ? (doc.scrollHeight - doc.clientHeight) : 0;
        var nodes = document.querySelectorAll("div,main,section,article");
        var limit = Math.min(nodes.length, 4000);
        for (var i = 0; i < limit; i++) {
          var el = nodes[i];
          var gap = el.scrollHeight - el.clientHeight;
          if (gap < 400 || el.clientHeight < 240) continue;
          var st;
          try { st = getComputedStyle(el); } catch (e) { continue; }
          if (st.overflowY !== "auto" && st.overflowY !== "scroll") continue;
          if (gap > bestGap) { bestGap = gap; best = el; }
        }
        return best;
      }
      // 一律读 body：它是所有滚动容器的超集。早期版本读「正在滚的那个容器」，
      // 实测在飞书上反而更少（606 字 vs body 的 816 字）——正文和面包屑分属不同子树。
      function wReadRoot() {
        return document.body;
      }
      function wState(reset) {
        var s = window.__wispCollector;
        if (reset || !s || !s.sc) {
          var sc = wFindScroller();
          s = {
            sc: sc,
            seen: Object.create(null),
            parts: [],
            startTop: sc ? sc.scrollTop : 0,
            steps: 0,
            bottom: false
          };
          window.__wispCollector = s;
        }
        return s;
      }
      // 把当前渲染出来的文字并进累积结果，返回这次新增了多少行。
      // 虚拟滚动会把同一块反复渲染，所以一律按整行内容去重。
      // 代价是文档里完全相同的两行会被合成一行——散文里极罕见；换来的是
      // 「正文」「封面」这类短标签不会每滚一屏就被重新追加一次。
      function wAbsorb(s) {
        var root = wReadRoot();
        var raw = root ? (root.innerText || root.textContent || "") : "";
        var lines = raw.split("\n");
        var added = 0;
        for (var i = 0; i < lines.length; i++) {
          var ln = lines[i].replace(/[ \t ​]+/g, " ").trim();
          if (!ln || s.seen[ln]) continue;
          s.seen[ln] = 1;
          s.parts.push(ln);
          added++;
        }
        return added;
      }
      function wCollectIframes(s) {
        var frames = document.querySelectorAll("iframe, frame");
        var pending = [];
        for (var i = 0; i < frames.length; i++) {
          var f = frames[i];
          var src = "";
          try { src = f.src || ""; } catch (e) { src = ""; }
          var got = false;
          try {
            var d = f.contentDocument;
            if (d && d.body) {
              var t = wClean(d.body.innerText);
              if (t) {
                s.parts.push("\n[嵌入框架 " + (src || "(同源)") + "]");
                s.parts.push(t);
                got = true;
              }
            }
          } catch (e) { got = false; }
          if (!got && src && src.indexOf("about:") !== 0) pending.push(src);
        }
        return pending;
      }
      """#

    /// 第一段：常规提取一次，顺便报告滚动容器的尺寸，供 Swift 侧判断要不要滚。
    static var beginJS: String {
        #"""
        (function () {
        \#(helpers)
          try {
            var s = wState(true);
            wAbsorb(s);
            var iframes = wCollectIframes(s);
            var sel = "";
            try { sel = wClean(window.getSelection().toString()); } catch (e) { sel = ""; }
            var sc = s.sc;
            var text = s.parts.join("\n");
            return JSON.stringify({
              title: document.title || "",
              href: location.href || "",
              text: text,
              selection: sel,
              iframes: iframes,
              scrollHeight: sc ? sc.scrollHeight : 0,
              clientHeight: sc ? sc.clientHeight : 0,
              scrollTop: sc ? sc.scrollTop : 0,
              docScroller: (!sc || sc === (document.scrollingElement || document.documentElement))
            });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        })()
        """#
    }

    /// 中间段（真实滚轮模式）：只吸收当前渲染出来的内容并报告进度，
    /// 滚动本身交给 `ScrollDriver` 发系统级事件——JS 改 `scrollTop` 驱动不了
    /// 飞书这类虚拟列表，实测滚到 3726px 渲染行数仍是 12 行。
    static var absorbJS: String {
        #"""
        (function () {
        \#(helpers)
          try {
            var s = window.__wispCollector;
            if (!s || !s.sc) return JSON.stringify({ error: "collector-missing" });
            var added = wAbsorb(s);
            s.gained = (s.gained || 0) + added;
            s.steps++;
            var sc = s.sc;
            var atBottom = (sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 6);
            if (atBottom) s.bottom = true;
            return JSON.stringify({
              added: added,
              gained: s.gained,
              atBottom: atBottom,
              chars: s.parts.join("\n").length,
              steps: s.steps
            });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        })()
        """#
    }

    /// 中间段：先吸收上一次滚动后新渲染的内容，再往下滚一屏。
    /// 上下重叠 120px，避免正好卡在行边界上漏掉一行。
    static var stepJS: String {
        #"""
        (function () {
        \#(helpers)
          try {
            var s = window.__wispCollector;
            if (!s || !s.sc) return JSON.stringify({ error: "collector-missing" });
            var added = wAbsorb(s);
            var sc = s.sc;
            var before = sc.scrollTop;
            var delta = Math.max(200, sc.clientHeight - 120);
            try { sc.scrollTop = before + delta; } catch (e) {}
            s.steps++;
            var moved = sc.scrollTop - before;
            var atBottom = moved <= 0 || (sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 4);
            if (atBottom) s.bottom = true;
            s.gained = (s.gained || 0) + added;
            return JSON.stringify({
              added: added,
              gained: s.gained,
              atBottom: atBottom,
              chars: s.parts.join("\n").length,
              steps: s.steps
            });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        })()
        """#
    }

    /// 收尾段：最后吸收一次，交出全文，并把滚动条放回用户原来的位置。
    static var finishJS: String {
        #"""
        (function () {
        \#(helpers)
          try {
            var s = window.__wispCollector;
            if (!s) return JSON.stringify({ error: "collector-missing" });
            wAbsorb(s);
            var text = s.parts.join("\n");
            var reached = !!s.bottom;
            var steps = s.steps;
            var gained = s.gained || 0;
            // JS 滚动模式下把滚动条放回原位；真实滚轮模式下 scrollTop 不生效，
            // 由 Swift 侧再发一串向上的滚轮事件复位。
            try { if (s.sc) s.sc.scrollTop = s.startTop; } catch (e) {}
            window.__wispCollector = null;
            return JSON.stringify({ text: text, reachedBottom: reached, steps: steps, gained: gained });
          } catch (e) {
            try { window.__wispCollector = null; } catch (e2) {}
            return JSON.stringify({ error: String(e) });
          }
        })()
        """#
    }

    /// 把任意字符串安全嵌入 AppleScript 的双引号字面量。
    static func appleScriptLiteral(_ s: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(s.count + 64)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(ch)
            }
        }
        return "\"" + escaped + "\""
    }
}
