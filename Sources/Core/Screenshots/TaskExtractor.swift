// MARK: - TaskExtractor
// 职责：任务动作的文本提取器——单号 / 地址 / 金额，纯函数。
// 任务卡：T12。输入为 OCR 文本；全半角、断行、易混字符先归一化再匹配。

import Foundation

enum TaskExtractor {

    // MARK: 归一化

    /// OCR 文本归一化：全角数字/字母 → 半角；数字内的换行与空格剔除
    /// （OCR 常把长单号断行）；易混字符仅在"疑似单号上下文"由正则容忍，
    /// 不做全局替换（避免误改普通文本）。
    static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if let folded = fullWidthFold[character] {
                result.append(folded)
            } else if character == "\n" || character == " " || character == "\u{00A0}" {
                result.append(character == "\n" ? "\n" : character)
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static let fullWidthFold: [Character: Character] = [
        "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
        "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
        "Ａ": "A", "Ｂ": "B", "Ｃ": "C", "Ｄ": "D", "Ｅ": "E", "Ｆ": "F",
        "Ｇ": "G", "Ｈ": "H", "Ｉ": "I", "Ｊ": "J", "Ｋ": "K", "Ｌ": "L",
        "Ｍ": "M", "Ｎ": "N", "Ｏ": "O", "Ｐ": "P", "Ｑ": "Q", "Ｒ": "R",
        "Ｓ": "S", "Ｔ": "T", "Ｕ": "U", "Ｖ": "V", "Ｗ": "W", "Ｘ": "X",
        "Ｙ": "Y", "Ｚ": "Z",
    ]

    /// 去掉数字串内部的断行/空格（仅作用于候选匹配阶段）。
    private static func squashedDigitsLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: 快递单号

    /// 单号形态：2 位大写字母 + 12–15 位数字（SF/YT/ZT…），或纯 12–15 位数字。
    /// 易混字符 O/I/Q 不出现在合法单号字母位——正则天然排除。
    private static let trackingPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z]{2}[0-9]{12,15}\b|\b[0-9]{13,15}\b"#
    )

    static func extractTrackingNo(_ rawText: String) -> String? {
        // 断行容错：把每行内以及跨行拼接两种视图都试一遍。
        let normalizedText = normalized(rawText)
        for candidate in [normalizedText, squashedDigitsLine(normalizedText)] {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = trackingPattern.firstMatch(in: candidate, range: range),
               let swiftRange = Range(match.range, in: candidate) {
                return String(candidate[swiftRange])
            }
        }
        return nil
    }

    // MARK: 地址

    /// 地址提取：取含最多地址要素词的连续行（省/市/区/路/栋/室…）。
    static func extractAddress(_ rawText: String) -> String? {
        let markers = ["省", "市", "区", "县", "路", "街", "道", "巷", "栋", "号楼", "单元", "室", "收货地址"]
        let lines = normalized(rawText)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var bestLine: String?
        var bestScore = 0
        for line in lines where line.count <= 80 {
            let score = markers.reduce(0) { $0 + (line.contains($1) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                bestLine = line
            }
        }
        // 至少命中 2 个要素才算地址。
        guard bestScore >= 2 else { return nil }
        return bestLine
    }

    // MARK: 金额

    /// 金额提取：¥/￥/$ 前缀或"实付/合计/总计"后缀的数值（支持千分位逗号与小数）。
    /// 返回按出现顺序的金额字符串（保留原始小数形态）。
    private static let amountPattern = try! NSRegularExpression(
        pattern: #"[¥￥$]\s*[0-9][0-9,]*(\.[0-9]{1,2})?|[0-9][0-9,]*(\.[0-9]{1,2})?\s*元"#
    )

    static func extractAmounts(_ rawText: String) -> [String] {
        let text = normalized(rawText)
        let range = NSRange(text.startIndex..., in: text)
        let matches = amountPattern.matches(in: text, range: range)
        return matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// 主金额：金额列表中数值最大者（账单页"合计"通常最大）。无金额返回 nil。
    static func extractPrimaryAmount(_ rawText: String) -> String? {
        let amounts = extractAmounts(rawText)
        guard !amounts.isEmpty else { return nil }
        return amounts.max { numericValue($0) < numericValue($1) }
    }

    private static func numericValue(_ amountString: String) -> Double {
        let digitsOnly = amountString.filter { $0.isNumber || $0 == "." }
        return Double(digitsOnly) ?? 0
    }
}
