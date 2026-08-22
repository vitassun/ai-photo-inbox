// MARK: - ScreenshotRuleClassifier
// 职责：截图规则分类器——关键词词典类别 + 版式特征，纯逻辑零依赖。
//       目标：70–80% 截图无需 LLM 即可定类；OCR 空/失败/低置信一律落
//       "待人工确认"（confidence ≤ 0.6 + suggestedAction=manual_review，
//       PRD 红线 5：低置信度不产生动作）。
// 任务卡：T11。词表入库（不含用户数据）；分类只做标记与动作入口，不触发删除。
// 任务卡：T13 将把 confidence < 0.6 的条目交给 LLM 兜底。

import Foundation

/// 分类结论（与 screenshot_classifications 表 DDL 词表严格对齐）。
struct ScreenshotVerdict: Equatable {
    /// DDL CHECK 词表内类别。
    let category: String
    /// [0,1]；≤ 0.6 视为待人工确认（PRD 红线 5）。
    let confidence: Double
    /// 提取字段 JSON（如快递单号），无提取时 "{}"。
    let extractedFieldsJSON: String
    /// 建议动作 id（copy_text / extract_tracking / mark_temporary / manual_review）。
    let suggestedAction: String
    /// 临时性 [0,1]（验证码类高、聊天记录中、账单低）。
    let temporaryLikelihood: Double

    /// 是否"待定"（PRD 红线 5 口径）。
    var needsManualReview: Bool { suggestedAction == "manual_review" }
}

enum ScreenshotRuleClassifier {

    // MARK: 词表（中文优先，附英文对照；来源见 feasibility §2.3）

    private static let verificationKeywords: [String] =
        ["验证码", "校验码", "动态码", "verification code", "otp"]
    private static let courierKeywords: [String] =
        ["快递", "单号", "运单", "物流", "揽收", "派送",
         "顺丰", "中通", "圆通", "申通", "韵达", "邮政", "ems", "tracking number"]
    private static let addressKeywords: [String] =
        ["收货地址", "省", "市", "区", "路", "街道", "栋", "单元", "室"]
    private static let boardingKeywords: [String] =
        ["登机牌", "航班", "登机口", "座位", "值机", "boarding pass", "flight", "gate", "seat"]
    private static let receiptKeywords: [String] =
        ["账单", "收据", "实付", "合计", "支付", "订单金额", "receipt", "total", "payment"]
    private static let chatKeywords: [String] =
        ["撤回", "语音通话", "视频通话", "对方正在输入", "已读"]
    private static let qrKeywords: [String] =
        ["二维码", "扫码", "扫一扫", "qr code"]
    private static let productKeywords: [String] =
        ["加入购物车", "包邮", "旗舰店", "商品详情", "好评", "加入购物车"]

    /// 快递单号形态：2 字母开头 + 12–15 位数字，或纯 13–15 位数字串。
    private static let trackingPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9])[A-Z]{2}\d{12,15}(?![0-9])|(?<![0-9])\d{13,15}(?![0-9])"#
    )

    // MARK: 主入口

    /// - Parameters:
    ///   - ocrText: OCR 文本；空/nil 视为识别失败 → 待人工确认。
    ///   - isScreenshot: PHAsset 子类型初筛结果。
    ///   - aspectRatio: 高/宽比（典型手机截图 ≥ 1.5）。
    static func classify(
        ocrText: String?,
        isScreenshot: Bool,
        aspectRatio: Double
    ) -> ScreenshotVerdict {
        guard let text = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            // OCR 空/失败：不许乱猜，落待定。
            return ScreenshotVerdict(
                category: "other", confidence: 0.0,
                extractedFieldsJSON: "{}",
                suggestedAction: "manual_review", temporaryLikelihood: 0.5
            )
        }

        let lowered = text.lowercased()
        let profile = LayoutAnalyzer.profile(ocrText: text)

        var scores: [(category: String, hits: Int, action: String, temp: Double)] = []
        func record(_ category: String, _ keywords: [String], _ action: String, _ temp: Double) {
            let hits = keywords.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
            if hits > 0 { scores.append((category, hits, action, temp)) }
        }

        record("verification_code", verificationKeywords, "mark_temporary", 0.95)
        record("courier", courierKeywords, "extract_tracking", 0.85)
        record("address", addressKeywords, "copy_text", 0.6)
        record("boarding_pass", boardingKeywords, "copy_text", 0.7)
        record("receipt", receiptKeywords, "copy_text", 0.4)
        record("chat", chatKeywords, "manual_review", 0.5)
        record("qr_code", qrKeywords, "mark_temporary", 0.8)
        record("product", productKeywords, "copy_text", 0.35)

        guard !scores.isEmpty else {
            return ScreenshotVerdict(
                category: "other", confidence: 0.3,
                extractedFieldsJSON: "{}",
                suggestedAction: "manual_review", temporaryLikelihood: 0.4
            )
        }

        // 取命中最多者；平手按固定词表顺序取先者——确定性。
        var best = scores[0]
        for candidate in scores.dropFirst() where candidate.hits > best.hits {
            best = candidate
        }

        // 置信度：命中数饱和到 3 个即满分；数字敏感类（验证码/快递）
        // 叠加版式加分——真实验证码/单号截图几乎总是单词命中 + 高数字密度。
        var confidence = min(1.0, Double(best.hits) / 3.0)
        let numericExpected = best.category == "verification_code" || best.category == "courier"
        if numericExpected, profile.digitDensity >= 0.10 {
            confidence += 0.35
        }
        confidence = min(confidence, 1.0)

        // 版式修正：
        // - 验证码/单号类期望高数字密度，密度低则降置信。
        if best.category == "verification_code" || best.category == "courier" {
            if profile.digitDensity < 0.08 { confidence *= 0.6 }
        }
        // - 非截图子类型或横屏内容削弱整体判定（utility 初筛信号）。
        if !isScreenshot { confidence *= 0.8 }
        if aspectRatio < 1.2 { confidence *= 0.85 }

        var fieldsJSON = "{}"
        if best.category == "courier",
           let match = trackingPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let trackingNo = String(text[range])
            let raw = #"{"tracking_no":"\#(trackingNo)"}"#
            fieldsJSON = raw
        }

        // 低置信度统一落待人工确认（PRD 红线 5）。
        let action = confidence <= 0.6 ? "manual_review" : best.action

        return ScreenshotVerdict(
            category: best.category,
            confidence: confidence,
            extractedFieldsJSON: fieldsJSON,
            suggestedAction: action,
            temporaryLikelihood: confidence <= 0.6 ? 0.5 : best.temp
        )
    }
}
