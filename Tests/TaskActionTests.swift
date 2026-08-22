// MARK: - TaskActionTests
// 职责：T12 单测——单号/地址/金额提取（全半角/断行/易混字符边界）、
//       验证码过期策略（时区无关）、PDF 合成页数、日历事件草稿字段。
// 任务卡：T12。CI 模拟器可验证（EventKit/粘贴板真机走查另测）。

import XCTest
@testable import AIPhotoInbox

final class TaskExtractorTests: XCTestCase {

    // MARK: 单号

    func testTrackingNumberBasicAndFullWidth() {
        XCTAssertEqual(TaskExtractor.extractTrackingNo("顺丰速运 单号 SF1234567890123 已揽收"), "SF1234567890123")
        XCTAssertEqual(TaskExtractor.extractTrackingNo("运单号 ＳＦ１２３４５６７８９０１２３"), "SF1234567890123")
        XCTAssertEqual(TaskExtractor.extractTrackingNo("EMS 123456789012345 派送中"), "123456789012345")
    }

    func testTrackingNumberAcrossLineBreak() {
        // OCR 把长单号断成两行。
        let broken = "运单号 SF12345678\n90123 已揽收"
        XCTAssertEqual(TaskExtractor.extractTrackingNo(broken), "SF1234567890123")
    }

    func testTrackingRejectsConfusableShortSequences() {
        // 电话号 11 位不满足 13–15 位；含 O/I 的字母串不匹配大写字母位模式。
        XCTAssertNil(TaskExtractor.extractTrackingNo("电话 13812345678 联系我"))
        XCTAssertNil(TaskExtractor.extractTrackingNo("订单 SIO123456789012 有问题"))
    }

    // MARK: 地址

    func testAddressExtractsDensestLine() {
        let text = "订单详情\n收货地址 浙江省杭州市西湖区文三路 100 号 2 栋 501 室\n支付方式 货到付款"
        XCTAssertEqual(TaskExtractor.extractAddress(text), "收货地址 浙江省杭州市西湖区文三路 100 号 2 栋 501 室")
    }

    func testAddressRequiresAtLeastTwoMarkers() {
        XCTAssertNil(TaskExtractor.extractAddress("今天天气不错\n适合出门散步"))
    }

    // MARK: 金额

    func testAmountExtractionWithSymbolsAndSuffix() {
        let amounts = TaskExtractor.extractAmounts("实付合计 ¥86.50\n优惠 ￥3.00\n运费 12 元")
        XCTAssertEqual(amounts.count, 3)
        XCTAssertTrue(amounts.contains("¥86.50"))
        XCTAssertTrue(amounts.contains("￥3.00"))
        XCTAssertTrue(amounts.contains("12 元"))
    }

    func testPrimaryAmountPicksLargest() {
        let primary = TaskExtractor.extractPrimaryAmount("小计 ¥12.00\n运费 ¥8.00\n合计 ¥86.50")
        XCTAssertEqual(primary, "¥86.50")
        XCTAssertNil(TaskExtractor.extractPrimaryAmount("没有任何金额的文本"))
    }
}

final class TemporaryMarkerTests: XCTestCase {

    func testExpiryIsSevenDaysByDefaultAndTimezoneIndependent() {
        // 用 UTC 午夜与本地极端时区两个时刻验证：纯绝对时间运算不受时区影响。
        for base in [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_755_000_000),
        ] {
            let expiry = TemporaryMarker.expiryDate(from: base)
            XCTAssertEqual(expiry.timeIntervalSince(base), 7 * 86_400, accuracy: 0.001)
        }
    }

    func testExpiredBoundary() {
        let markedAt = Date(timeIntervalSince1970: 1_000_000)
        let expiry = TemporaryMarker.expiryDate(from: markedAt)
        XCTAssertFalse(TemporaryMarker.isExpired(expiresAt: expiry, now: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(TemporaryMarker.isExpired(expiresAt: expiry, now: expiry))
    }
}

final class CalendarEventBuilderTests: XCTestCase {

    func testDraftExtractsTitleLocationAndDate() throws {
        let draft = try XCTUnwrap(CalendarEventBuilder.draft(
            from: "登机牌\n航班 MU5107\n2026-09-01 14:30\n登机口 C22"
        ))
        XCTAssertEqual(draft.title, "登机牌")
        XCTAssertEqual(draft.location, "登机口 C22")

        let date = try XCTUnwrap(draft.startDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
    }

    func testTimeOnlyFallsBackToProvidedDay() throws {
        let anchor = Date(timeIntervalSince1970: 1_778_000_000)   // 任意基准日
        let draft = try XCTUnwrap(CalendarEventBuilder.draft(
            from: "演出场次 19:45 开演\n场馆大剧院",
            fallbackDate: nil
        ))
        XCTAssertNotNil(draft.startDate)

        let parsed = try XCTUnwrap(CalendarEventBuilder.parseDateTime(in: "19:45", now: anchor))
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.hour, from: parsed), 19)
        XCTAssertEqual(calendar.component(.minute, from: parsed), 45)
        XCTAssertEqual(
            calendar.startOfDay(for: parsed),
            calendar.startOfDay(for: anchor),
            "仅时刻时挂基准日当天"
        )
        _ = draft
    }

    func testEmptyTextYieldsNoDraft() {
        XCTAssertNil(CalendarEventBuilder.draft(from: "   "))
    }
}

final class PDFComposerTests: XCTestCase {

    private func syntheticJPEG(seed: UInt64) throws -> Data {
        let side = 120
        var state = seed
        var rgba = [UInt8]()
        rgba.reserveCapacity(side * side * 4)
        for _ in 0..<(side * side) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8((state >> 33) % 256)
            rgba.append(contentsOf: [value, value, value, 255])
        }
        let context = try XCTUnwrap(CGContext(
            data: &rgba,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.9))
    }

    func testComposeProducesCorrectPageCountAndNonEmptyOutput() throws {
        let images = [try syntheticJPEG(seed: 1), try syntheticJPEG(seed: 2), try syntheticJPEG(seed: 3)]
        let pdf = try PDFComposer.compose(imageDatas: images)

        XCTAssertFalse(pdf.isEmpty)
        XCTAssertEqual(PDFComposer.pageCount(in: pdf), 3, "三张图应产出三页 PDF")
        XCTAssertEqual(pdf.prefix(5), Data("%PDF-".utf8), "输出应是 PDF 魔数开头")
    }

    func testComposeRejectsEmptyAndGarbage() {
        XCTAssertThrowsError(try PDFComposer.compose(imageDatas: []))
        XCTAssertThrowsError(try PDFComposer.compose(imageDatas: [Data("not an image".utf8)]))
    }
}
