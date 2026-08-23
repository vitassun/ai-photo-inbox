// MARK: - TaskActionExecutors
// 职责：四个任务动作的真实执行器（T15 接线）——粘贴板写入、临时标记策略、
//       EventKit 写入适配层、PDF 合成。全部用户显式点击触发，绝不自动执行；
//       权限最小化：日历只申请写事件权限，绝不读用户日历内容。
// 任务卡：T12（纯逻辑）/ T15（执行器接线）。

import Foundation
import EventKit
import UIKit

/// 日历写入抽象（测试注入假实现；生产 EventKitCalendarWriter）。
protocol CalendarWriting {
    /// 只申请写权限（iOS 17+ write-only scope）。被拒返回 false。
    func requestWriteAccess() async -> Bool
    /// 写入事件草稿。抛错 = 失败态（UI 明确提示，不吞原截图状态）。
    func write(draft: CalendarEventDraft) async throws
}

final class EventKitCalendarWriter: CalendarWriting {

    private let store = EKEventStore()

    func requestWriteAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestWriteOnlyAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func write(draft: CalendarEventDraft) async throws {
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarWriteError.noWritableCalendar
        }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.location = draft.location
        event.startDate = draft.startDate ?? Date().addingTimeInterval(3_600)
        event.endDate = event.startDate.addingTimeInterval(3_600)
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    enum CalendarWriteError: LocalizedError {
        case noWritableCalendar

        var errorDescription: String? {
            switch self {
            case .noWritableCalendar:
                return "没有可写入的日历（请在系统设置 → 日历中确认账户）"
            }
        }
    }
}

/// 动作执行结果（UI Toast / 分享面板用）。
enum TaskActionOutcome: Equatable {
    case copied(String)
    case markedTemporary(expiryDate: Date)
    case calendarEventCreated
    case pdfReady(fileURL: URL)
}

enum TaskActionExecutor {

    enum ActionError: LocalizedError {
        case nothingToCopy
        case calendarAccessDenied
        case pdfComposeFailed

        var errorDescription: String? {
            switch self {
            case .nothingToCopy:
                return "没有可复制的文本（识别结果为空）"
            case .calendarAccessDenied:
                return "日历写入权限被拒绝，可到系统设置开启后重试"
            case .pdfComposeFailed:
                return "PDF 生成失败（图片读取异常）"
            }
        }
    }

    // MARK: ① 复制文本

    /// 提取字段优先（如快递单号），回退 OCR 全文。
    @discardableResult
    static func copyText(fieldsJSON: String, ocrText: String) throws -> TaskActionOutcome {
        if let field = firstFieldValue(in: fieldsJSON) {
            UIPasteboard.general.string = field
            return .copied(field)
        }
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ActionError.nothingToCopy }
        UIPasteboard.general.string = text
        return .copied(text)
    }

    // MARK: ② 临时标记（验证码）

    /// 7 天后到期（TemporaryMarker 策略）。decisions 落库由调用方用
    /// TemporaryMarker.reasonWithExpiry 组装（保持执行器无 DB 依赖）。
    static func markTemporary(now: Date = Date()) -> TaskActionOutcome {
        .markedTemporary(expiryDate: TemporaryMarker.expiryDate(from: now))
    }

    // MARK: ③ 日历事件（登机牌）

    static func createCalendarEvent(
        ocrText: String,
        writer: CalendarWriting
    ) async throws -> TaskActionOutcome {
        guard await writer.requestWriteAccess() else {
            throw ActionError.calendarAccessDenied
        }
        // 提取不到标题不硬造事件——报错让用户手动处理（T12 边界）。
        guard let draft = CalendarEventBuilder.draft(from: ocrText) else {
            throw ActionError.nothingToCopy
        }
        try await writer.write(draft: draft)
        return .calendarEventCreated
    }

    // MARK: ④ 收据转 PDF

    /// 整图一页 PDF 写入临时目录；分享面板由 UI 层用返回的 fileURL 弹出。
    @discardableResult
    static func exportPDF(imageData: Data) throws -> TaskActionOutcome {
        let pdf = try PDFComposer.compose(imageDatas: [imageData])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-\(Int(Date().timeIntervalSince1970)).pdf")
        try pdf.write(to: url, options: .atomic)
        return .pdfReady(fileURL: url)
    }

    // MARK: 辅助

    /// extracted_fields JSON 的首个非空字符串值（V1 词表只有 tracking_no 一类）。
    static func firstFieldValue(in fieldsJSON: String) -> String? {
        guard let data = fieldsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (_, value) in object.sorted(by: { $0.key < $1.key }) {
            if let string = value as? String, !string.isEmpty { return string }
        }
        return nil
    }
}
