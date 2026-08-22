// MARK: - DailyInboxTests
// 职责：T14 单测——摘要聚合窗口边界、通知文案三档、触发时刻计算
//       （UTC 与夏令时时区）、数据库计数助手。
// 任务卡：T14。CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class DailySummaryAggregatorTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testCountsOnlyWithinDayWindow() {
        let dayStart = day(2026, 8, 22)
        let newAssets: [(id: String, date: Date)] = [
            ("a", day(2026, 8, 22, 8)),          // 窗口内
            ("b", day(2026, 8, 22, 23, 59)),     // 窗口内（最后一分钟）
            ("c", day(2026, 8, 21, 12)),         // 前一天 → 不计
            ("d", dayStart.addingTimeInterval(-1)), // 恰好早一秒 → 不计
        ]
        let actions: [(id: String, date: Date)] = [
            ("t1", dayStart),                    // 恰好等于零点 → 计入当日
            ("t2", dayStart.addingTimeInterval(86_400)), // 恰好次日零点 → 不计
        ]

        let summary = DailySummaryAggregator.summarize(
            newAssets: newAssets,
            pendingDeletionIDs: ["p1", "p2", "p3"],
            actionEvents: actions,
            dayStart: dayStart
        )

        XCTAssertEqual(summary.newAssetCount, 2)
        XCTAssertEqual(summary.actionCount, 1)
        XCTAssertEqual(summary.pendingDeletionCount, 3, "待删计数是当前集合大小，不做时间窗过滤")
        XCTAssertEqual(summary.dayStart, dayStart)
    }

    func testEmptyDayGivesZeroSummary() {
        let summary = DailySummaryAggregator.summarize(
            newAssets: [], pendingDeletionIDs: [], actionEvents: [],
            dayStart: day(2026, 8, 22)
        )
        XCTAssertEqual(summary.newAssetCount, 0)
        XCTAssertEqual(summary.pendingDeletionCount, 0)
        XCTAssertEqual(summary.actionCount, 0)
    }

    func testDuplicateAssetIDsAreCountedIndividually() {
        // 同 id 不同时间（如连拍多张同标识异常）也如实计数——聚合器不做去重语义。
        let dayStart = day(2026, 8, 22)
        let summary = DailySummaryAggregator.summarize(
            newAssets: [("a", dayStart), ("a", dayStart.addingTimeInterval(60))],
            pendingDeletionIDs: [],
            actionEvents: [],
            dayStart: dayStart
        )
        XCTAssertEqual(summary.newAssetCount, 2)
    }
}

final class DailyNotificationContentTests: XCTestCase {

    private let dayStart = Date(timeIntervalSince1970: 1_770_000_000)

    private func summary(new: Int, pending: Int = 2, actions: Int = 1) -> DailyInboxSummary {
        DailyInboxSummary(dayStart: dayStart, newAssetCount: new,
                          pendingDeletionCount: pending, actionCount: actions)
    }

    func testZeroNewPhotosUsesQuietCopy() {
        let body = DailyNotificationContent.body(for: summary(new: 0))
        XCTAssertTrue(body.contains("没有新照片"), body)
        XCTAssertFalse(body.contains("新增 0"), "空态不该出现零计数句式")
    }

    func testSmallBatchCopy() {
        let body = DailyNotificationContent.body(for: summary(new: 3))
        XCTAssertTrue(body.contains("新增 3 张"), body)
        XCTAssertTrue(body.contains("2 张待确认"), body)
        XCTAssertTrue(body.contains("1 条任务"), body)
    }

    func testLargeBatchCopy() {
        let body = DailyNotificationContent.body(for: summary(new: 42, pending: 10, actions: 5))
        XCTAssertTrue(body.contains("新增 42 张"), body)
        XCTAssertTrue(body.contains("10 张待确认"), body)
        XCTAssertTrue(body.contains("5 条任务待处理"), body)
    }

    // MARK: 触发时刻（时区/夏令时无关）

    func testNextTriggerTodayOrTomorrowUTC() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 10)))

        let trigger = try XCTUnwrap(DailyNotificationContent.nextTriggerDate(
            after: now, hour: 21, minute: 0, calendar: utc
        ))
        let comps = utc.dateComponents([.year, .month, .day, .hour, .minute], from: trigger)
        XCTAssertEqual(comps.hour, 21)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.day, 22, "10 点看 21 点的提醒 → 今天")

        let lateNow = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 22)))
        let tomorrowTrigger = try XCTUnwrap(DailyNotificationContent.nextTriggerDate(
            after: lateNow, hour: 21, calendar: utc
        ))
        XCTAssertEqual(utc.component(.day, from: tomorrowTrigger), 23, "22 点已过 21 点 → 明天")
    }

    func testTriggerSurvivesDSTSpringForward() throws {
        // 纽约 2026-03-08 02:00 春季拨快：02:30 不存在——日历算术应自行折算不崩。
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeJump = try XCTUnwrap(newYork.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1
        )))

        let trigger = try XCTUnwrap(DailyNotificationContent.nextTriggerDate(
            after: beforeJump, hour: 2, minute: 30, calendar: newYork
        ))
        let comps = newYork.dateComponents([.day, .hour, .minute], from: trigger)
        XCTAssertEqual(comps.day, 9, "当天 2:30 不存在，顺延到明天")
        XCTAssertEqual(comps.hour, 2)
        XCTAssertEqual(comps.minute, 30)
    }
}

final class DailyInboxDatabaseCountsTests: XCTestCase {

    private func makeRecord(id: String, creation: Date?) -> AssetRecord {
        AssetRecord(
            localIdentifier: id, favorite: false, isEdited: false,
            mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
            creationDate: creation, isScreenshot: false, isLivePhoto: false,
            latitude: nil, longitude: nil
        )
    }

    func testStoreBackedCountsFeedSummary() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let windowStart = Date(timeIntervalSince1970: 1_700_000_000)

        database.upsert(asset: makeRecord(id: "today-1", creation: windowStart.addingTimeInterval(60)),
                        fetchedAt: Date())
        database.upsert(asset: makeRecord(id: "today-2", creation: windowStart.addingTimeInterval(120)),
                        fetchedAt: Date())
        database.upsert(asset: makeRecord(id: "old", creation: windowStart.addingTimeInterval(-86_400)),
                        fetchedAt: Date())
        database.setDecision(assetId: "today-1", verdict: .delete, reason: "similar_group",
                             decidedAt: windowStart.addingTimeInterval(300))
        database.markActionTaken(assetId: "today-2", action: "copy_text",
                                 at: windowStart.addingTimeInterval(600))

        XCTAssertEqual(database.countAssets(createdAtOrAfter: windowStart), 2)
        XCTAssertEqual(database.countDeleteVerdicts(), 1)
        XCTAssertEqual(database.countActions(atOrAfter: windowStart), 1)

        // 与聚合器拼成完整摘要。
        let summary = DailyInboxSummary(
            dayStart: windowStart,
            newAssetCount: database.countAssets(createdAtOrAfter: windowStart),
            pendingDeletionCount: database.countDeleteVerdicts(),
            actionCount: database.countActions(atOrAfter: windowStart)
        )
        XCTAssertEqual(DailyNotificationContent.body(for: summary).contains("新增 2 张"), true)
    }
}
