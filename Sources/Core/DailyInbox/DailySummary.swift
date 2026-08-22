// MARK: - DailyInboxSummary
// 职责：Daily Inbox 的摘要聚合与通知文案/触发时刻计算，全部纯函数。
// 任务卡：T14。摘要只含计数与中性文案——不含缩略图、OCR 文本等敏感内容。

import Foundation

/// 一天的 Daily Inbox 摘要。
struct DailyInboxSummary: Equatable {
    /// 摘要归属日的当天零点（摘要时区的日历语义）。
    let dayStart: Date
    let newAssetCount: Int
    let pendingDeletionCount: Int
    let actionCount: Int
}

enum DailySummaryAggregator {

    /// 聚合当日增量。窗口 = [dayStart, dayStart + 1 天)，跨天边界：
    /// 恰好等于 dayStart 计入当日，恰好等于次日零点计入下一天。
    /// - Parameters:
    ///   - newAssets: 当日新增（拍摄时间）(id, creationDate) 列表。
    ///   - pendingDeletionIDs: 当前预删除候选集（已过 SafetyRules）。
    ///   - actionEvents: 任务动作事件 (id, 发生时间)。
    static func summarize(
        newAssets: [(id: String, date: Date)],
        pendingDeletionIDs: [String],
        actionEvents: [(id: String, date: Date)],
        dayStart: Date
    ) -> DailyInboxSummary {
        let windowEnd = dayStart.addingTimeInterval(86_400)
        let inWindow: (Date) -> Bool = { $0 >= dayStart && $0 < windowEnd }

        return DailyInboxSummary(
            dayStart: dayStart,
            newAssetCount: newAssets.filter { inWindow($0.date) }.count,
            pendingDeletionCount: pendingDeletionIDs.count,
            actionCount: actionEvents.filter { inWindow($0.1) }.count
        )
    }

    /// 本地日历的"今天零点"。
    static func dayStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}

enum DailyNotificationContent {

    /// 通知正文：0 / 少量 / 大量三档中性文案（只含计数，无敏感内容）。
    static func body(for summary: DailyInboxSummary) -> String {
        switch summary.newAssetCount {
        case 0:
            return "今天相册没有新照片，一切如常。"
        case 1...9:
            var parts = ["今天新增 \(summary.newAssetCount) 张照片"]
            if summary.pendingDeletionCount > 0 {
                parts.append("有 \(summary.pendingDeletionCount) 张待确认")
            }
            if summary.actionCount > 0 {
                parts.append("\(summary.actionCount) 条任务可处理")
            }
            return parts.joined(separator: "，") + "。"
        default:
            var parts = ["今天新增 \(summary.newAssetCount) 张照片"]
            if summary.pendingDeletionCount > 0 {
                parts.append("\(summary.pendingDeletionCount) 张待确认")
            }
            if summary.actionCount > 0 {
                parts.append("\(summary.actionCount) 条任务待处理")
            }
            return parts.joined(separator: "，") + "，打开看看吧。"
        }
    }

    /// 下一次触发时刻：今天或明天的 hour:minute（用日历算术，
    /// 时区/夏令时安全——不存在的时间由 Calendar 自行折算）。
    static func nextTriggerDate(
        after now: Date,
        hour: Int,
        minute: Int = 0,
        calendar: Calendar = .current
    ) -> Date? {
        var todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
        todayComponents.hour = hour
        todayComponents.minute = minute
        guard let todaySlot = calendar.date(from: todayComponents) else { return nil }
        if todaySlot > now { return todaySlot }
        return calendar.date(byAdding: .day, value: 1, to: todaySlot)
    }
}
