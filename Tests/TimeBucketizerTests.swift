// MARK: - TimeBucketizerTests
// 职责：时间分桶纯函数的边界测试（空/单元素/阈值边界/跨天/乱序）。
// 任务卡：T04 / T01（CI 首跑验证）。纯逻辑，模拟器可跑，无需真机。

import XCTest
@testable import AIPhotoInbox

final class TimeBucketizerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(offsetSeconds: TimeInterval) -> Date {
        base.addingTimeInterval(offsetSeconds)
    }

    func testEmptyInputReturnsNoBuckets() {
        XCTAssertTrue(TimeBucketizer.bucketize([], gapThreshold: 1800).isEmpty)
    }

    func testSingleEntryReturnsSingleBucket() {
        let result = TimeBucketizer.bucketize([("a", date(offsetSeconds: 0))], gapThreshold: 1800)
        XCTAssertEqual(result, [["a"]])
    }

    func testEntriesWithinGapStayInOneBucket() {
        let result = TimeBucketizer.bucketize([
            ("a", date(offsetSeconds: 0)),
            ("b", date(offsetSeconds: 600)),
            ("c", date(offsetSeconds: 1200)),
        ], gapThreshold: 1800)
        XCTAssertEqual(result, [["a", "b", "c"]])
    }

    func testGapBeyondThresholdSplitsBuckets() {
        let result = TimeBucketizer.bucketize([
            ("a", date(offsetSeconds: 0)),
            ("b", date(offsetSeconds: 600)),
            ("c", date(offsetSeconds: 3600)),
        ], gapThreshold: 1800)
        XCTAssertEqual(result, [["a", "b"], ["c"]])
    }

    func testExactThresholdDoesNotSplit() {
        // 间隔恰好等于阈值：严格大于才切 → 同桶。
        let result = TimeBucketizer.bucketize([
            ("a", date(offsetSeconds: 0)),
            ("b", date(offsetSeconds: 1800)),
        ], gapThreshold: 1800)
        XCTAssertEqual(result, [["a", "b"]])
    }

    func testCrossMidnightSmallGapStaysTogether() {
        // 跨天本身不切桶，只看间隔：23:50 与次日 00:10 相隔 20 分钟 → 同桶。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let nearMidnight = calendar.date(
            from: DateComponents(year: 2025, month: 6, day: 1, hour: 23, minute: 50)
        ) else {
            return XCTFail("构造跨天日期失败")
        }
        let afterMidnight = nearMidnight.addingTimeInterval(20 * 60)
        let result = TimeBucketizer.bucketize([
            ("night", nearMidnight),
            ("dawn", afterMidnight),
        ], gapThreshold: 1800)
        XCTAssertEqual(result, [["night", "dawn"]])
    }

    func testOvernightLargeGapSplits() {
        let result = TimeBucketizer.bucketize([
            ("day1", date(offsetSeconds: 0)),
            ("day2", date(offsetSeconds: 24 * 3600)),
        ], gapThreshold: 1800)
        XCTAssertEqual(result, [["day1"], ["day2"]])
    }

    func testUnsortedInputIsSortedByDate() {
        let result = TimeBucketizer.bucketize([
            ("late", date(offsetSeconds: 7200)),
            ("early", date(offsetSeconds: 0)),
            ("mid", date(offsetSeconds: 300)),
        ], gapThreshold: 1800)
        XCTAssertEqual(result, [["early", "mid"], ["late"]])
    }

    func testDefaultThresholdIsThirtyMinutes() {
        // 不传 gapThreshold 时默认 1800 秒：29 分钟同桶、31 分钟切桶。
        let same = TimeBucketizer.bucketize([
            ("a", date(offsetSeconds: 0)),
            ("b", date(offsetSeconds: 29 * 60)),
        ])
        let split = TimeBucketizer.bucketize([
            ("a", date(offsetSeconds: 0)),
            ("b", date(offsetSeconds: 31 * 60)),
        ])
        XCTAssertEqual(same, [["a", "b"]])
        XCTAssertEqual(split, [["a"], ["b"]])
    }
}
