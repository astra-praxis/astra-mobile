import SwiftUI

// MARK: - 轻量 Markdown 渲染
// 与桌面端手机页 renderAssistantText 同一子集：``` 围栏代码 / # 标题 / - 1. 列表 /
// > 引用 / --- 分隔线；行内：`code`、**粗体**、__粗体__、*斜体*、_斜体_。
// 手写解析零依赖，流式期间未闭合语法按普通文本显示，闭合后自动成形。

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([(marker: String, text: String)])
    case quote([String])
    case code(lang: String, body: String)
    case hr
}

extension String {
    var fullRange: NSRange { NSRange(location: 0, length: (self as NSString).length) }
}

extension NSTextCheckingResult {
    /// 捕获组安全取值：越界或未命中返回 nil。
    /// 直接调 range(at:) 越界会抛 NSInvalidArgumentException，Swift 捕获不到 → SIGABRT 闪退。
    func groupRange(_ index: Int) -> NSRange? {
        guard index >= 0, index < numberOfRanges else { return nil }
        let r = range(at: index)
        return r.location == NSNotFound ? nil : r
    }
}

enum MarkdownParser {

    /// 解析全文为块数组。围栏未闭合时余下内容按代码体展示（与手机页一致）
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var rest = raw
        while true {
            if let open = rest.range(of: "```") {
                if open.lowerBound > rest.startIndex {
                    parseBlocks(String(rest[..<open.lowerBound]), into: &blocks)
                }
                let after = rest[open.upperBound...]
                guard let nl = after.firstIndex(of: "\n") else {
                    let lang = normalizeLang(String(after))
                    if !lang.isEmpty || !after.isEmpty {
                        blocks.append(.code(lang: lang, body: ""))
                    }
                    rest = ""
                    break
                }
                let lang = normalizeLang(String(after[..<nl]))
                let tail = after[after.index(after: nl)...]
                if let close = tail.range(of: "```") {
                    var body = String(tail[..<close.lowerBound])
                    if body.hasSuffix("\n") { body.removeLast() }
                    blocks.append(.code(lang: lang, body: body))
                    rest = String(tail[close.upperBound...])
                } else {
                    var body = String(tail)
                    if body.hasSuffix("\n") { body.removeLast() }
                    blocks.append(.code(lang: lang, body: body))
                    rest = ""
                    break
                }
            } else {
                parseBlocks(rest, into: &blocks)
                rest = ""
                break
            }
        }
        return blocks
    }

    private static func normalizeLang(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 与手机页同规则：语言标识限 [\w+#.-]{1,16}，否则视为无语言
        if t.isEmpty || t.count > 16 { return "" }
        for ch in t where !(ch.isLetter || ch.isNumber || ch == "#" || ch == "." || ch == "-" || ch == "_") {
            return ""
        }
        return t
    }

    /// 块级排版：标题 / 列表 / 引用 / 分隔线 / 段落（逻辑对齐 appendMarkdownBlocks）
    private static func parseBlocks(_ text: String, into blocks: inout [MarkdownBlock]) {
        var bullets: [String] = []
        var ordered: [(String, String)] = []
        var quote: [String] = []
        var mode = ""  // "ul" | "ol" | "quote"

        func flush() {
            switch mode {
            case "ul": blocks.append(.bullet(bullets)); bullets = []
            case "ol": blocks.append(.ordered(ordered)); ordered = []
            case "quote": blocks.append(.quote(quote)); quote = []
            default: break
            }
            mode = ""
        }

        func capture(_ i: Int, _ m: NSTextCheckingResult, in s: String) -> String? {
            guard let r = m.groupRange(i), let idx = Range(r, in: s) else { return nil }
            return String(s[idx])
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)

            if let hm = headRE.firstMatch(in: l, range: l.fullRange),
               let hashes = hm.groupRange(1), let textRange = hm.groupRange(2),
               let r1 = Range(hashes, in: l), let r2 = Range(textRange, in: l) {
                flush()
                blocks.append(.heading(level: min(l[r1].count, 3), text: String(l[r2])))
                continue
            }
            if hrRE.firstMatch(in: l, range: l.fullRange) != nil {
                flush(); blocks.append(.hr); continue
            }
            if let m = ulRE.firstMatch(in: l, range: l.fullRange),
               let item = capture(1, m, in: l) {
                if mode != "ul" { flush(); mode = "ul" }
                bullets.append(item)
                continue
            }
            if let m = olRE.firstMatch(in: l, range: l.fullRange),
               let marker = capture(1, m, in: l), let text = capture(2, m, in: l) {
                if mode != "ol" { flush(); mode = "ol" }
                ordered.append((marker, text))
                continue
            }
            if let m = qmRE.firstMatch(in: l, range: l.fullRange),
               let line = capture(1, m, in: l) {
                if mode != "quote" { flush(); mode = "quote" }
                quote.append(line)
                continue
            }
            flush()
            if l.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            blocks.append(.paragraph(l))
        }
        flush()
    }

    // 与手机页同款的行内定界正则：`code` / **b** / __b__ / *i* / _i_
    static let inlineRE = try! NSRegularExpression(
        pattern: "(`+)([^`]*?)\\1|\\*\\*([^*]+?)\\*\\*|__([^_]+?)__|\\*([^*\\n]+?)\\*|_([^_\\n]+?)_")
    // 组 1 = 井号数量（层级），组 2 = 标题正文；两个分组缺一不可，读取组号越界会抛异常闪退
    private static let headRE = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$")
    private static let hrRE = try! NSRegularExpression(pattern: "^\\s*(-{3,}|\\*{3,}|_{3,})\\s*$")
    private static let ulRE = try! NSRegularExpression(pattern: "^\\s*[-*+]\\s+(.+)$")
    private static let olRE = try! NSRegularExpression(pattern: "^\\s*(\\d+)[.)]\\s+(.+)$")
    private static let qmRE = try! NSRegularExpression(pattern: "^\\s*>\\s?(.*)$")
}

// MARK: - 行内渲染：把一段文本按定界符切分为 AttributedString

enum MarkdownInline {

    /// 行内格式 → AttributedString。未配对的定界符原样保留
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        var last = 0
        while last < ns.length {
            let range = NSRange(location: last, length: ns.length - last)
            guard let m = MarkdownParser.inlineRE.firstMatch(in: text, options: [], range: range),
                  m.range.length > 0 else { break }
            if m.range.location > last {
                out.append(plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            let capture: (Int) -> String = { i in
                guard let r = m.groupRange(i), let idx = Range(r, in: text) else { return "" }
                return String(text[idx])
            }
            // 组 2 = 行内代码（可为空）；组 3/4 = 粗体；组 5/6 = 斜体
            if m.groupRange(2) != nil {
                var code = AttributedString(capture(2))
                code.font = .system(.callout, design: .monospaced)
                code.backgroundColor = .init(.secondarySystemBackground)
                out.append(code)
            } else if let boldRange = firstNonNotFound(m, groups: 3, 4), let r = Range(boldRange, in: text) {
                var bold = AttributedString(String(text[r]))
                bold.font = .body.bold()
                out.append(bold)
            } else if let emRange = firstNonNotFound(m, groups: 5, 6), let r = Range(emRange, in: text) {
                var em = AttributedString(String(text[r]))
                em.font = .body.italic()
                out.append(em)
            } else {
                // 不应发生（正则命中必有一个备选组）；原样输出防丢字
                out.append(plain(ns.substring(with: m.range)))
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length {
            out.append(plain(ns.substring(from: last)))
        }
        return out
    }

    private static func firstNonNotFound(_ m: NSTextCheckingResult, groups: Int...) -> NSRange? {
        for g in groups {
            if let r = m.groupRange(g) { return r }
        }
        return nil
    }

    private static func plain(_ s: String) -> AttributedString {
        AttributedString(s)
    }
}

// MARK: - SwiftUI 渲染

struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            switch level {
            case 1: inlineText(text).font(.title2.bold())
            case 2: inlineText(text).font(.title3.bold())
            default: inlineText(text).font(.headline)
            }
        case .paragraph(let text):
            inlineText(text)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inlineText(item)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker + ".")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        inlineText(item.text)
                    }
                }
            }
        case .quote(let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        inlineText(line).foregroundStyle(.secondary)
                    }
                }
            }
        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground))
                }
                Text(body)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        case .hr:
            Divider()
        }
    }

    private func inlineText(_ s: String) -> some View {
        Text(MarkdownInline.attributed(s))
    }
}
