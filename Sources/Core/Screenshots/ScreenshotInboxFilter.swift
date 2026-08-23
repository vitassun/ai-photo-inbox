// MARK: - ScreenshotInboxFilter
// 职责：截图任务箱列表页（P8）的纯展示逻辑——时间窗互斥分桶、"待定"口径、
//       类别显示名与动作路由（category → 四动作）。零依赖，CI 可全测。
// 任务卡：T15。

import Foundation

/// 时间筛选三档（PRD P8：本周 / 30 天 / 更早）——互斥分桶而非叠加过滤。
enum ScreenshotTimeWindow: String, CaseIterable {
    case thisWeek = "本周"
    case last30Days = "30 天"
    case older = "更早"

    /// 资产创建时间落入本桶？creationDate 为 nil 归入"更早"。
    /// 分桶规则：≥ 本周起点 → 本周；否则 ≥ now−30d → 30 天；否则更早。
    /// （周起点恒 ≥ now−7d > now−30d，三桶严格不交。）
    static func bucket(
        of creationDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> ScreenshotTimeWindow {
        guard let creationDate else { return .older }
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
           creationDate >= weekStart {
            return .thisWeek
        }
        if creationDate >= now.addingTimeInterval(-30 * 86_400) { return .last30Days }
        return .older
    }
}

enum ScreenshotInboxFilter {

    /// DDL 九类词表（chips 展示顺序与 screenshot_classifications CHECK 约束对齐）。
    static let categoryOrder = [
        "courier", "verification_code", "boarding_pass", "product",
        "address", "receipt", "qr_code", "chat", "other",
    ]

    /// 类别显示名。
    static let categoryNames: [String: String] = [
        "courier": "快递",
        "verification_code": "验证码",
        "boarding_pass": "登机牌",
        "product": "商品",
        "address": "地址",
        "receipt": "收据",
        "qr_code": "二维码",
        "chat": "聊天",
        "other": "其他",
    ]

    /// "待定"口径（红线 5）：置信度 ≤ 0.6 或建议动作为人工确认。
    static func isPending(confidence: Double, suggestedAction: String) -> Bool {
        confidence <= 0.6 || suggestedAction == "manual_review"
    }

    static func displayName(for category: String) -> String {
        categoryNames[category] ?? category
    }
}

/// 动作路由：按类别映射四动作（PRD P9）；manual_review / 低置信永不产生写动作。
/// 覆盖关系以类别为准（分类器把 boarding_pass 建议成 copy_text，
/// 但 PRD 指定登机牌 → 日历事件——路由层是产品语义的最终裁决点）。
enum ScreenshotActionRouter {

    static func primaryAction(
        category: String,
        confidence: Double,
        suggestedAction: String
    ) -> ScreenshotTaskAction? {
        // 红线 5 双保险：低置信或人工确认一律不给主动作。
        guard confidence > 0.6, suggestedAction != "manual_review" else { return nil }

        switch category {
        case "verification_code":
            return .markTemporary
        case "courier", "address":
            return .copyText
        case "boarding_pass":
            return .createCalendarEvent
        case "receipt":
            return .exportPDF
        default:
            // qr_code / chat / product / other：V1 无自动动作入口。
            return nil
        }
    }
}
