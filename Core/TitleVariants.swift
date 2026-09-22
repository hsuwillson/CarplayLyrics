import Foundation

/// 產生多種歌名寫法，用來在 LRCLIB 找不到時放寬搜尋
/// 例：「中文名 English Name (Live) - Remastered」→ 原名、去括號/後綴、只留中日韓文字、只留英文
/// 日文歌另外處理：全形英數/空白、「～TV size～」這類裝飾、「曲名 / 副標」
enum TitleVariants {
    static func make(_ title: String) -> [String] {
        var results: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !results.contains(t) { results.append(t) }
        }

        add(title)
        let normalized = normalizeWidth(title)
        add(normalized)
        let stripped = stripDecorations(normalized)
        add(stripped)

        // 「曲名 / 副標」→ 只取斜線前
        if let r = stripped.range(of: " / ") {
            add(String(stripped[..<r.lowerBound]))
        }

        let cjk = stripped.unicodeScalars.filter(isCJK)
        let hasCJK = !cjk.isEmpty
        let hasLatin = stripped.unicodeScalars.contains { $0.properties.isAlphabetic && $0.isASCII }
        if hasCJK && hasLatin {
            add(String(String.UnicodeScalarView(stripped.unicodeScalars.filter { isCJK($0) || $0 == " " })))
            add(String(String.UnicodeScalarView(stripped.unicodeScalars.filter { !isCJK($0) })))
        }
        return results
    }

    /// 去掉 (…)、[…]、（…）、【…】 以及 " - xxx" 後綴
    static func stripDecorations(_ title: String) -> String {
        var s = title
        let patterns = [
            #"\([^)]*\)"#, #"\[[^\]]*\]"#, #"（[^）]*）"#, #"【[^】]*】"#,
            #"[～〜~][^～〜~]*[～〜~]"#,   // 日文常見：～TV size～、〜Short ver.〜
            #"-[^-]*ver\.?-"#,             // -TV ver.-
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 全形英數符號 → 半形、全形空白 → 半形空白（不動日文假名）
    static func normalizeWidth(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xFF01...0xFF5E:
                scalars.append(Unicode.Scalar(u.value - 0xFEE0)!)
            case 0x3000:
                scalars.append(" ")
            default:
                scalars.append(u)
            }
        }
        return String(scalars)
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF,   // 平假名、片假名
             0x31F0...0x31FF,   // 片假名擴充
             0xFF66...0xFF9F,   // 半形片假名
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // 漢字
             0xAC00...0xD7AF:   // 韓文
            return true
        default: return false
        }
    }
}
