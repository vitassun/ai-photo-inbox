// MARK: - TaskActions
// 职责：四个任务动作的纯逻辑域——验证码过期策略、日历事件草稿构造、
//       动作路由。EventKit 写入 / 粘贴板 / PDF 分享由 Infrastructure 与
//       UI 执行（用户显式点击触发，绝不自动执行——T12 边界）。
// 任务卡：T12。

import Foundation

/// 验证码"临时标记"策略：默认 7 天后进入清理提醒列表。
enum TemporaryMarker {

    /// 默认保留天数（PRD：验证码类截图挂 7 天清理建议）。
    static let defaultRetentionDays = 7

    /// 过期时间点 = 标记时刻 + N 天（绝对时间运算，时区无关）。
    static func expiryDate(from markedAt: Date, days: Int = defaultRetentionDays) -> Date {
        markedAt.addingTimeInterval(Double(days) * 86_400)
    }

    /// 是否已到期（时区无关：纯绝对时间比较）。
    static func isExpired(expiresAt: Date, now: Date) -> Bool {
        now >= expiresAt
    }
}

/// 日历事件草稿：从票面/日程 OCR 文本提取的写入前对象。
/// 真正写 EventKit 由 Infrastructure 的 CalendarWriting 适配层完成
/// （权限最小化：只申请写事件，不读用户日历内容）。
struct CalendarEventDraft: Equatable {
    var title: String
    var startDate: Date?
    var location: String?
}

enum CalendarEventBuilder {

    /// 从登机牌/票面文本构造草稿。提取不到标题时返回 nil（不硬造事件）。
    static func draft(from ocrText: String, fallbackDate: Date? = nil) -> CalendarEventDraft? {
        let lines = ocrText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let titleLine = lines.first(where: { line in
            ["航班", "登机牌", "车次", "演出", "场次"].contains { line.contains($0) }
        }) ?? lines.first else { return nil }

        // 地点：含"口/厅/站/馆"的短行优先（登机口 C22 / 候车厅…）。
        let location = lines.first { line in
            line.count <= 20 && ["口", "厅", "站", "馆"].contains { line.contains($0) }
        }

        return CalendarEventDraft(
            title: titleLine,
            startDate: parseDateTime(in: ocrText) ?? fallbackDate,
            location: location
        )
    }

    /// 时间解析：支持 "2026-09-01 14:30"、"9月1日 14:30"、"14:30" 三档；
    /// 无年份时取当前年（跨年场景 V1 不处理，属真机走查项）。
    static func parseDateTime(in text: String, now: Date = Date()) -> Date? {
        let fullForm = try! NSRegularExpression(pattern: #"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})[ T]?(\d{1,2}):(\d{2})?"#)
        let textRange = NSRange(text.startIndex..., in: text)

        if let match = fullForm.firstMatch(in: text, range: textRange) {
            var comps = DateComponents()
            func group(_ index: Int) -> Int {
                let r = match.range(at: index)
                guard r.location != NSNotFound, let swiftRange = Range(r, in: text),
                      let value = Int(text[swiftRange]) else { return 0 }
                return value
            }
            comps.year = group(1)
            comps.month = group(2)
            comps.day = group(3)
            comps.hour = group(4)
            comps.minute = match.range(at: 5).location == NSNotFound ? 0 : group(5)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: comps)
        }

        // 仅时刻："14:30" → 挂在 now 当天。
        let timeOnly = try! NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})\b"#)
        if let match = timeOnly.firstMatch(in: text, range: textRange) {
            let hour = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? 0
            let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            var day = calendar.dateComponents([.year, .month, .day], from: now)
            day.hour = hour
            day.minute = minute
            return calendar.date(from: day)
        }
        return nil
    }
}

/// 任务动作种类（UI 路由 + verdicts 记录用）。
enum ScreenshotTaskAction: String {
    case markTemporary = "mark_temporary"
    case copyText = "copy_text"
    case createCalendarEvent = "create_calendar_event"
    case exportPDF = "export_pdf"
    case manualReview = "manual_review"
}
