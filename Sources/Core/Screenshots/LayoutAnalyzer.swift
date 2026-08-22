// MARK: - LayoutAnalyzer
// 职责：截图版式特征提取——行切分、数字密度、按钮状短行、状态栏残影。
//       纯函数：输入 OCR 文本字符串，输出可比较的版式画像。
// 任务卡：T11。阈值集中本文件常量区，注释来源。

import Foundation

/// 一张截图的版式画像。
struct LayoutProfile: Equatable {
    /// 非空文本行数。
    let lineCount: Int
    /// 数字字符占全部字符比例 [0,1]（验证码/单号类截图显著偏高）。
    let digitDensity: Double
    /// 短行（≤ shortLineMaxChars 字符）占非空行比例 [0,1]（按钮状短行）。
    let shortLineRatio: Double
    /// 首行是否疑似状态栏残影（运营商/时间/电量模式）。
    let hasStatusBarRemnant: Bool
}

enum LayoutAnalyzer {

    // MARK: 版式阈值（调参入口：真机 50 张走查后修订）

    /// 短行判定上限（字符数）。
    static let shortLineMaxChars = 4
    /// 状态栏残影：首行匹配"运营商 + 时间 + 电量"的典型要素。
    static let statusBarKeywords: [String] = ["中国移动", "中国联通", "中国电信", "5G", "4G", "WiFi"]

    /// 从 OCR 文本提取版式画像。空文本 → 全零画像（lineCount=0）。
    static func profile(ocrText: String) -> LayoutProfile {
        let lines = ocrText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return LayoutProfile(lineCount: 0, digitDensity: 0, shortLineRatio: 0, hasStatusBarRemnant: false)
        }

        let allCharacters = lines.joined()
        let total = allCharacters.count
        let digits = allCharacters.filter { $0.isNumber }.count
        let shortLines = lines.filter { $0.count <= shortLineMaxChars }.count

        let firstLine = lines[0]
        let statusBarHit = firstLine.count <= 30
            && statusBarKeywords.contains { firstLine.localizedCaseInsensitiveContains($0) }

        return LayoutProfile(
            lineCount: lines.count,
            digitDensity: total > 0 ? Double(digits) / Double(total) : 0,
            shortLineRatio: Double(shortLines) / Double(lines.count),
            hasStatusBarRemnant: statusBarHit
        )
    }
}
