// MARK: - ScreenshotClassifierTests
// 职责：T11 单测——版式特征逐项断言、规则分类器各类别与边界（空文本/
//       纯英文/中英混排/长文摘录）、内置合成截图集分类覆盖率 ≥ 70%、
//       引擎截图子管线落表冒烟。
// 任务卡：T11。CI 模拟器可验证（覆盖率采用"预置 OCR 结果"口径并固定）。

import XCTest
@testable import AIPhotoInbox

final class LayoutAnalyzerTests: XCTestCase {

    func testLineSplittingAndDigitDensity() {
        let profile = LayoutAnalyzer.profile(ocrText: "顺丰速运\n单号 SF123456789012\n已签收")
        XCTAssertEqual(profile.lineCount, 3)
        // 数字字符 12 / 全部字符（去换行后 3+13+3=19）≈ 0.63。
        XCTAssertGreaterThan(profile.digitDensity, 0.5)
        XCTAssertEqual(profile.shortLineRatio, 2.0 / 3.0, accuracy: 0.001)
    }

    func testEmptyTextGivesZeroProfile() {
        let profile = LayoutAnalyzer.profile(ocrText: "  \n \n")
        XCTAssertEqual(profile.lineCount, 0)
        XCTAssertEqual(profile.digitDensity, 0)
        XCTAssertEqual(profile.shortLineRatio, 0)
        XCTAssertFalse(profile.hasStatusBarRemnant)
    }

    func testStatusBarRemnantDetection() {
        XCTAssertTrue(LayoutAnalyzer.profile(ocrText: "中国移动 12:30 88%").hasStatusBarRemnant)
        XCTAssertTrue(LayoutAnalyzer.profile(ocrText: "5G 下午三点 WiFi").hasStatusBarRemnant)
        XCTAssertFalse(LayoutAnalyzer.profile(ocrText: "验证码 582914").hasStatusBarRemnant)
    }
}

final class ScreenshotRuleClassifierTests: XCTestCase {

    private func classify(_ text: String?, isScreenshot: Bool = true,
                          aspectRatio: Double = 2.16) -> ScreenshotVerdict {
        ScreenshotRuleClassifier.classify(ocrText: text, isScreenshot: isScreenshot, aspectRatio: aspectRatio)
    }

    // MARK: 各类别

    func testVerificationCodeDetectedWithHighTemporality() {
        let verdict = classify("【支付宝】验证码 582914，10 分钟内有效。")
        XCTAssertEqual(verdict.category, "verification_code")
        XCTAssertGreaterThan(verdict.confidence, 0.6)
        XCTAssertEqual(verdict.suggestedAction, "mark_temporary")
        XCTAssertGreaterThanOrEqual(verdict.temporaryLikelihood, 0.9)
    }

    func testCourierDetectedAndTrackingExtracted() throws {
        let verdict = classify("顺丰快递\n运单号 SF1234567890123\n已揽收")
        XCTAssertEqual(verdict.category, "courier")
        XCTAssertGreaterThan(verdict.confidence, 0.6)
        XCTAssertEqual(verdict.suggestedAction, "extract_tracking")

        let fields = try XCTUnwrap(JSONDecoder().decode([String: String].self, from: Data(verdict.extractedFieldsJSON.utf8)))
        XCTAssertEqual(fields["tracking_no"], "SF1234567890123")
    }

    func testBoardingPassDetected() {
        let verdict = classify("登机牌\n航班 MU5107\n登机口 C22 座位 33F")
        XCTAssertEqual(verdict.category, "boarding_pass")
        XCTAssertEqual(verdict.suggestedAction, "copy_text")
    }

    func testReceiptDetected() {
        let verdict = classify("支付账单\n实付合计 ¥86.50\n订单已送达")
        XCTAssertEqual(verdict.category, "receipt")
        XCTAssertLessThan(verdict.temporaryLikelihood, 0.6)
    }

    func testEnglishOnlyTextClassifies() {
        let verdict = classify("Tracking number: SF8888888888888\nPicked up")
        XCTAssertEqual(verdict.category, "courier")

        let code = classify("Your verification code is 483920")
        XCTAssertEqual(code.category, "verification_code")
    }

    func testMixedChineseEnglishClassifies() {
        let verdict = classify("EMS Express 运单号 1234567890123 派送中 tracking")
        XCTAssertEqual(verdict.category, "courier")
    }

    // MARK: 边界：空文本 / 无命中 / 低置信落待定

    func testNilOrEmptyTextAlwaysPending() {
        for text in [nil as String?, "", "   "] {
            let verdict = classify(text)
            XCTAssertTrue(verdict.needsManualReview, "OCR 空/失败必须落待定")
            XCTAssertEqual(verdict.category, "other")
            XCTAssertEqual(verdict.confidence, 0.0)
        }
    }

    func testLongEssayWithoutSignalsIsManualReview() {
        let essay = Array(repeating: "这是一段没有任何信号词的普通文章内容，讲述天气与心情。", count: 10).joined()
        let verdict = classify(essay)
        XCTAssertTrue(verdict.needsManualReview)
        XCTAssertLessThanOrEqual(verdict.confidence, 0.6)
    }

    func testLowSignalHitFallsBackToManualReview() {
        // 只命中一个弱关键词且版式不配合 → 置信度被压到 ≤0.6 → 待定。
        let verdict = classify("地址", aspectRatio: 1.0)
        XCTAssertTrue(verdict.needsManualReview)
    }

    func testNonScreenshotSubtypeWeakensConfidence() {
        let strong = classify("验证码 582914", isScreenshot: true)
        let weak = classify("验证码 582914", isScreenshot: false)
        XCTAssertLessThan(weak.confidence, strong.confidence)
    }

    // MARK: 覆盖率 ≥70%（预置 OCR 结果口径，固定样本集）

    func testBuiltinSampleSetCoverageAtLeastSeventyPercent() {
        // (预期类别, 预置 OCR 文本) —— 模拟真实截图典型内容。
        let samples: [(String, String)] = [
            ("verification_code", "【微信】验证码 204817，请勿泄露"),
            ("verification_code", "Google verification code: 771234"),
            ("verification_code", "短信验证码 995511，5分钟内输入"),
            ("courier", "中通快递 单号 78123456789012 已发货"),
            ("courier", "圆通速递 运单号 YT1234567890123 派送中"),
            ("courier", "顺丰速运 快递单号 SF9876543210987"),
            ("boarding_pass", "登机牌 CA1831 登机口 E18 座位 42C"),
            ("boarding_pass", "BOARDING PASS Flight CZ3456 GATE D7 SEAT 21A"),
            ("receipt", "美团订单 实付合计 ¥45.00 支付成功"),
            ("receipt", "电子收据 合计金额 ¥128.90 谢谢惠顾"),
            ("address", "收货地址 浙江省杭州市西湖区文三路 100 号 2 栋 501 室"),
            ("qr_code", "扫一扫二维码加入群聊"),
            ("product", "商品详情 限时包邮 加入购物车 立即购买"),
            ("chat", "对方撤回了一条消息 语音通话已取消"),
            ("other", "系统设置页面 无任何信号词汇的正常界面文字"),
            ("other", "一张纯风景图片上的随机水印文字 ABC"),
            ("other", "备忘录 今天记得买牛奶和面包"),
            ("other", "日历视图 周三 周四 周五 周六 周日"),
            ("other", "相簿回忆 幻灯片播放背景音乐列表"),
            ("other", "控制中心 蓝牙 飞行模式 亮度调节"),
        ]
        let expectedNonOther = samples.filter { $0.0 != "other" }

        var hits = 0
        var pendingCount = 0
        for (expected, text) in samples {
            let verdict = ScreenshotRuleClassifier.classify(
                ocrText: text, isScreenshot: true, aspectRatio: 2.16
            )
            if verdict.category == expected && !verdict.needsManualReview {
                hits += 1
            }
            if verdict.needsManualReview { pendingCount += 1 }
        }

        let coverage = Double(hits) / Double(samples.count)
        XCTAssertGreaterThanOrEqual(coverage, 0.7, "合成样本分类覆盖率 \(coverage) < 70%")
        // 待定占比 ≤ 30%（PRD 口径）。
        XCTAssertLessThanOrEqual(Double(pendingCount) / Double(samples.count), 0.3)
        _ = expectedNonOther
    }
}

// MARK: 引擎截图子管线落表冒烟

final class ScreenshotPipelineEngineTests: XCTestCase {

    func testEngineClassifiesScreenshotsIntoTable() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.shot")

        // 两张截图 + 一张普通照片。
        var records: [AssetRecord] = []
        for index in 0..<3 {
            records.append(AssetRecord(
                localIdentifier: "asset-\(index)",
                favorite: false, isEdited: false, mediaType: .image,
                pixelWidth: 1170, pixelHeight: 2532, duration: 0,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 3600)),
                isScreenshot: index < 2,
                isLivePhoto: false, latitude: nil, longitude: nil
            ))
        }
        let fakeService = FakePhotoLibraryService(records: records)

        // 路由技巧：loader 返回 "ocr::<id>" 标记数据，OCR 闭包解码出 id 后
        // 查预置文本表（引擎的 OCR 注入只拿得到 Data）。
        let ocrTexts = [
            "asset-0": "【银行】短信验证码 664400，切勿告知他人",
            "asset-1": "顺丰快递 运单号 SF1234567890123 已揽收",
        ]
        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            imageDataLoader: { id in Data(("ocr::" + id).utf8) },
            hashComputer: { _ in nil },
            embeddingComputer: { _ in nil },
            featureAnalyzer: { _ in nil },
            screenshotOCR: { data in
                guard let marker = String(data: data, encoding: .utf8),
                      marker.hasPrefix("ocr::") else { return nil }
                return ocrTexts[String(marker.dropFirst(5))]
            },
            workQueue: queue
        )
        engine.runFullScan { _, _ in }
        queue.sync { }

        // 只有截图进分类表；预置文本命中预期类别。
        let classifiedIds = database.screenshotClassificationAssetIds()
        XCTAssertEqual(classifiedIds, Set(["asset-0", "asset-1"]), "仅 isScreenshot 资产进分类表")

        let code = try XCTUnwrap(database.screenshotClassification(assetId: "asset-0"))
        XCTAssertEqual(code.category, "verification_code")
        XCTAssertEqual(code.suggestedAction, "mark_temporary")
        XCTAssertGreaterThan(code.confidence, 0.6)

        let courier = try XCTUnwrap(database.screenshotClassification(assetId: "asset-1"))
        XCTAssertEqual(courier.category, "courier")
        XCTAssertEqual(courier.suggestedAction, "extract_tracking")
        let fields = try XCTUnwrap(
            JSONDecoder().decode([String: String].self, from: Data(courier.extractedFieldsJSON.utf8))
        )
        XCTAssertEqual(fields["tracking_no"], "SF1234567890123")

        // 普通照片不进表。
        XCTAssertNil(database.screenshotClassification(assetId: "asset-2"))
    }
}

private extension PhotoLibraryDatabase.ScreenshotClassification {
    /// 判定是否待人工确认（suggestedAction == manual_review）。
    func needsManualReviewFlag() -> Bool { suggestedAction == "manual_review" }
}
