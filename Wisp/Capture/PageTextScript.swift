import Foundation

/// 注入到浏览器当前分页里的提取脚本。返回一段 JSON 字符串。
enum PageTextScript {
    static let js: String = #"""
(function () {
  function clean(s) {
    return String(s || "")
      .replace(/[ \t ]+/g, " ")
      .replace(/\n[ ]+/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }
  try {
    var out = { title: "", href: "", text: "", selection: "", iframes: [] };
    out.title = document.title || "";
    out.href = location.href || "";

    var body = document.body;
    var text = body ? clean(body.innerText) : "";
    if (body && text.replace(/\s+/g, "").length < 40) {
      var tc = clean(body.textContent);
      if (tc.length > text.length) text = tc;
    }

    try { out.selection = clean(window.getSelection().toString()); } catch (e) { out.selection = ""; }

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
          var t = clean(d.body.innerText);
          if (t) {
            text += "\n\n[嵌入框架 " + (src || "(同源)") + "]\n" + t;
            got = true;
          }
        }
      } catch (e) { got = false; }
      if (!got && src && src.indexOf("about:") !== 0) pending.push(src);
    }

    out.text = text;
    out.iframes = pending;
    return JSON.stringify(out);
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})()
"""#

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
