import Foundation

/// 產生多種歌名寫法，用來在 LRCLIB 找不到時放寬搜尋
/// 例：「中文名 English Name (Live) - Remastered」→ 原名、去括號/後綴、只留中文、只留英文
enum TitleVariants {
    static func make(_ title: String) -> [String] {
        var results: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !results.contains(t) { results.append(t) }
        }

        add(title)
        let stripped = stripDecorations(title)
        add(stripped)

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
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"（[^）]*）"#, #"【[^】]*】"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
