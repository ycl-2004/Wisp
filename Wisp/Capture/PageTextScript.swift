import Foundation

/// 注入到浏览器当前分页里的提取脚本，返回一个 JSON 字符串。
///
/// 只读当前渲染出来的内容，不滚动页面，也不在页面里留下任何状态。飞书文档、Notion
/// 这类虚拟滚动应用只有可视区域附近的块在 DOM 里，所以可能只读到一屏。
enum PageTextScript {

    /// 一次读完：正文、选中文字、同源 iframe 的正文，以及标题和网址。
    ///
    /// 一律读 body：它是所有滚动容器的超集。早期版本读「正在滚的那个容器」，
    /// 实测在飞书上反而更少（606 字 vs body 的 816 字）——正文和面包屑分属不同子树。
    /// 重复行原样保留：代码里的 `}`、`return`，表格里相同的数值都是真内容。
    static var readJS: String {
        #"""
        (function () {
          function wClean(s) {
            return String(s || "")
              .replace(/[ \t\u00A0\u200B]+/g, " ")
              .replace(/\n[ ]+/g, "\n")
              .replace(/\n{3,}/g, "\n\n")
              .trim();
          }
          try {
            var parts = [];
            var root = document.body;
            var raw = root ? (root.innerText || root.textContent || "") : "";
            var lines = raw.split("\n");
            for (var i = 0; i < lines.length; i++) {
              var ln = lines[i].replace(/[ \t\u00A0\u200B]+/g, " ").trim();
              if (ln) parts.push(ln);
            }
            var pending = [];
            var frames = document.querySelectorAll("iframe, frame");
            for (var k = 0; k < frames.length; k++) {
              var f = frames[k];
              var src = "";
              try { src = f.src || ""; } catch (e) { src = ""; }
              var got = false;
              try {
                var d = f.contentDocument;
                if (d && d.body) {
                  var t = wClean(d.body.innerText);
                  if (t) {
                    parts.push("\n[嵌入框架 " + (src || "(同源)") + "]");
                    parts.push(t);
                    got = true;
                  }
                }
              } catch (e) { got = false; }
              if (!got && src && src.indexOf("about:") !== 0) pending.push(src);
            }
            var sel = "";
            try { sel = wClean(window.getSelection().toString()); } catch (e) { sel = ""; }
            return JSON.stringify({
              title: document.title || "",
              href: location.href || "",
              text: parts.join("\n"),
              selection: sel,
              iframes: pending
            });
          } catch (e) {
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
