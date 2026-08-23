// MARK: - ScreenshotInboxTests
// 职责：T15 截图任务箱——时间窗分桶、"待定"口径、动作路由、执行器、
//       联表查询与已处理标记。全部纯逻辑/内存库，CI 模拟器可验证。

import XCTest
import UIKit
@testable import AIPhotoInbox

final class ScreenshotInboxTests: XCTestCase {

    private let calendar = Calendar.current
    private lazy var now: Date = {
        // 固定"现在"，避开跨周/跨月漂移导致的分桶抖动。
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 20
        components.hour = 15
        return calendar.date(from: components)!
    }()

    // MARK: 时间窗分桶（互斥三桶）

    func testBucketThisWeekBoundary() {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        XCTAssertEqual(
            ScreenshotTimeWindow.bucket(of: weekStart, now: now, calendar: calendar),
            .thisWeek,
            "恰好本周起点 → 本周"
        )
        let beforeWeek = weekStart.addingTimeInterval(-1)
        XCTAssertNotEqual(
            ScreenshotTimeWindow.bucket(of: beforeWeek, now: now, calendar: calendar),
            .thisWeek
        )
    }

    func testBucketThirtyDaysAndOlder() {
        let in30Days = now.addingTimeInterval(-29 * 86_400)
        XCTAssertEqual(
            ScreenshotTimeWindow.bucket(of: in30Days, now: now, calendar: calendar),
            .last30Days,
            "29 天前且不在本周 → 30 天桶"
        )
        let older = now.addingTimeInterval(-31 * 86_400)
        XCTAssertEqual(
            ScreenshotTimeWindow.bucket(of: older, now: now, calendar: calendar),
            .older
        )
    }

    func testBucketNilDateFallsToOlder() {
        XCTAssertEqual(ScreenshotTimeWindow.bucket(of: nil, now: now, calendar: calendar), .older)
    }

    // MARK: 待定口径（红线 5）

    func testPendingThreshold() {
        XCTAssertTrue(ScreenshotInboxFilter.isPending(confidence: 0.6, suggestedAction: "copy_text"),
                      "置信度恰为 0.6 → 待人工确认")
        XCTAssertTrue(ScreenshotInboxFilter.isPending(confidence: 0.9, suggestedAction: "manual_review"))
        XCTAssertFalse(ScreenshotInboxFilter.isPending(confidence: 0.85, suggestedAction: "copy_text"))
    }

    // MARK: 动作路由（类别优先；低置信/待定永不产生写动作）

    func testRouterCategoryMapping() {
        XCTAssertEqual(
            ScreenshotActionRouter.primaryAction(category: "verification_code", confidence: 0.95, suggestedAction: "mark_temporary"),
            .markTemporary
        )
        XCTAssertEqual(
            ScreenshotActionRouter.primaryAction(category: "courier", confidence: 0.9, suggestedAction: "extract_tracking"),
            .copyText
        )
        XCTAssertEqual(
            ScreenshotActionRouter.primaryAction(category: "address", confidence: 0.7, suggestedAction: "copy_text"),
            .copyText
        )
        XCTAssertEqual(
            ScreenshotActionRouter.primaryAction(category: "boarding_pass", confidence: 0.8, suggestedAction: "copy_text"),
            .createCalendarEvent,
            "PRD P9：登机牌 → 日历事件（覆盖分类器的 copy_text 建议）"
        )
        XCTAssertEqual(
            ScreenshotActionRouter.primaryAction(category: "receipt", confidence: 0.8, suggestedAction: "copy_text"),
            .exportPDF
        )
        XCTAssertNil(
            ScreenshotActionRouter.primaryAction(category: "other", confidence: 0.9, suggestedAction: "manual_review")
        )
    }

    func testRouterNeverRoutesLowConfidenceOrManualReview() {
        for category in ScreenshotInboxFilter.categoryOrder {
            XCTAssertNil(
                ScreenshotActionRouter.primaryAction(category: category, confidence: 0.5, suggestedAction: "export_pdf"),
                "低置信 \(category) 不得路由任何写动作（红线 5）"
            )
            XCTAssertNil(
                ScreenshotActionRouter.primaryAction(category: category, confidence: 0.95, suggestedAction: "manual_review"),
                "manual_review 的 \(category) 不得路由任何写动作"
            )
        }
    }

    // MARK: 执行器

    func testCopyTextPrefersExtractedFieldThenOCR() throws {
        UIPasteboard.general.string = ""
        let outcome = try TaskActionExecutor.copyText(
            fieldsJSON: #"{"tracking_no":"SF1234567890123"}"#,
            ocrText: "顺丰速运\n运单 SF1234567890123"
        )
        guard case .copied(let text) = outcome else { return XCTFail("期望 copied") }
        XCTAssertEqual(text, "SF1234567890123")
        XCTAssertEqual(UIPasteboard.general.string, "SF1234567890123")

        _ = try TaskActionExecutor.copyText(fieldsJSON: "{}", ocrText: "第一行\n第二行")
        XCTAssertEqual(UIPasteboard.general.string, "第一行\n第二行", "无提取字段时回退 OCR 全文")
    }

    func testCopyTextThrowsWhenNothingToCopy() {
        XCTAssertThrowsError(try TaskActionExecutor.copyText(fieldsJSON: "{}", ocrText: "   "))
    }

    func testMarkTemporaryUsesSevenDayPolicy() {
        let markedAt = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .markedTemporary(let expiry) = TaskActionExecutor.markTemporary(now: markedAt) else {
            return XCTFail("期望 markedTemporary")
        }
        XCTAssertEqual(expiry, TemporaryMarker.expiryDate(from: markedAt))
        XCTAssertEqual(expiry.timeIntervalSince(markedAt), 7 * 86_400, accuracy: 1)

        // reason 往返：落库串可解回过期时间，且兼容 action:% 统计口径。
        let reason = TemporaryMarker.reasonWithExpiry(from: markedAt)
        XCTAssertTrue(reason.hasPrefix("action:"), "countActions 按 LIKE 'action:%' 统计")
        XCTAssertEqual(TemporaryMarker.expiry(fromReason: reason), expiry)
    }

    func testCreateCalendarEventDeniedAccessThrowsAndKeepsStateClean() async {
        final class DeniedWriter: CalendarWriting {
            func requestWriteAccess() async -> Bool { false }
            func write(draft: CalendarEventDraft) async throws {
                XCTFail("无权限时不得触达写入")
            }
        }
        do {
            _ = try await TaskActionExecutor.createCalendarEvent(ocrText: "航班 CA1234", writer: DeniedWriter())
            XCTFail("权限被拒应抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("日历"), "错误态需明确可见")
        }
    }

    func testCreateCalendarEventWritesDraftOnGrantedAccess() async throws {
        final class RecordingWriter: CalendarWriting {
            private(set) var written: CalendarEventDraft?
            func requestWriteAccess() async -> Bool { true }
            func write(draft: CalendarEventDraft) async throws { written = draft }
        }
        let writer = RecordingWriter()
        let outcome = try await TaskActionExecutor.createCalendarEvent(
            ocrText: "登机牌 CA1234\n2026-09-01 14:30\n登机口 C22",
            writer: writer
        )
        guard case .calendarEventCreated = outcome else { return XCTFail("期望 calendarEventCreated") }
        XCTAssertEqual(writer.written?.title, "登机牌 CA1234")
        XCTAssertEqual(writer.written?.location, "登机口 C22")
        XCTAssertNotNil(writer.written?.startDate, "应解析出 2026-09-01 14:30")
    }

    func testExportPDFProducesOnePageFile() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let jpeg = image.jpegData(compressionQuality: 0.9)!

        guard case .pdfReady(let url) = try TaskActionExecutor.exportPDF(imageData: jpeg) else {
            return XCTFail("期望 pdfReady")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(PDFComposer.pageCount(in: data), 1)
    }

    // MARK: DB 联表查询与已处理标记

    private func makeAsset(_ id: String, creationDate: Date?) -> AssetRecord {
        AssetRecord(
            localIdentifier: id, favorite: false, isEdited: false,
            mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
            creationDate: creationDate, isScreenshot: true, isLivePhoto: false,
            latitude: nil, longitude: nil
        )
    }

    private func seedClassification(
        _ db: PhotoLibraryDatabase, assetId: String,
        category: String, confidence: Double, action: String
    ) {
        db.upsertScreenshotClassification(PhotoLibraryDatabase.ScreenshotClassification(
            assetId: assetId, category: category, confidence: confidence,
            extractedFieldsJSON: "{}", suggestedAction: action,
            temporaryLikelihood: 0.5, source: "rule",
            classifiedAt: now, ocrText: "示例 OCR 文本"
        ))
    }

    func testInboxRowsFilteringOrderingAndProcessedFlag() {
        let database = try! PhotoLibraryDatabase.inMemory()

        let old = now.addingTimeInterval(-40 * 86_400)
        let mid = now.addingTimeInterval(-10 * 86_400)
        let fresh = now.addingTimeInterval(-3600)
        database.upsert(asset: makeAsset("a-old", creationDate: old), fetchedAt: now)
        database.upsert(asset: makeAsset("a-mid", creationDate: mid), fetchedAt: now)
        database.upsert(asset: makeAsset("a-new", creationDate: fresh), fetchedAt: now)

        seedClassification(database, assetId: "a-old", category: "courier", confidence: 0.9, action: "extract_tracking")
        seedClassification(database, assetId: "a-mid", category: "receipt", confidence: 0.8, action: "copy_text")
        seedClassification(database, assetId: "a-new", category: "receipt", confidence: 0.3, action: "manual_review")

        // 全量 + 降序。
        let all = database.screenshotInboxRows(category: nil)
        XCTAssertEqual(all.map(\.assetId), ["a-new", "a-mid", "a-old"])

        // 类别过滤。
        XCTAssertEqual(database.screenshotInboxRows(category: "receipt").map(\.assetId), ["a-new", "a-mid"])
        XCTAssertTrue(database.screenshotInboxRows(category: "boarding_pass").isEmpty)

        // 待定口径进列表行。
        XCTAssertTrue(all.first { $0.assetId == "a-new" }!.isPending)
        XCTAssertFalse(all.first { $0.assetId == "a-mid" }!.isPending)

        // OCR 全文随 v2 列往返。
        XCTAssertEqual(all[0].ocrText, "示例 OCR 文本")

        // 动作执行后 → isProcessed 翻转 + 徽标计数归零。
        XCTAssertEqual(database.countPendingScreenshotTasks(), 2)
        database.markActionTaken(assetId: "a-mid", action: "copy_text")
        let after = database.screenshotInboxRows(category: nil)
        XCTAssertTrue(after.first { $0.assetId == "a-mid" }!.isProcessed)
        XCTAssertEqual(database.countPendingScreenshotTasks(), 1)
    }

    func testOcrTextUpsertDoesNotClobberExistingTextWithEmpty() {
        let database = try! PhotoLibraryDatabase.inMemory()
        database.upsert(asset: makeAsset("a-1", creationDate: now), fetchedAt: now)

        seedClassification(database, assetId: "a-1", category: "courier", confidence: 0.9, action: "extract_tracking")

        // LLM 兜底回写分类但不带文本 → 不清空已有 OCR。
        database.upsertScreenshotClassification(PhotoLibraryDatabase.ScreenshotClassification(
            assetId: "a-1", category: "courier", confidence: 0.95,
            extractedFieldsJSON: "{}", suggestedAction: "extract_tracking",
            temporaryLikelihood: 0.5, source: "llm",
            classifiedAt: now, ocrText: ""
        ))
        XCTAssertEqual(database.screenshotClassification(assetId: "a-1")?.ocrText, "示例 OCR 文本")
    }
}
