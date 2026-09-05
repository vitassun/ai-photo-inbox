// MARK: - LowQualityDetectorTests
// 职责：T16 低质量检测——纯判定分支、曝光占比 DSP、EXIF 解析真数据往返、
//       引擎集成（快照构成/裁决落库/豁免不落删除/红线过滤/user_override 尊重）。
// 任务卡：T16。CI 模拟器可验证。

import XCTest
import UIKit
@testable import AIPhotoInbox

final class LowQualityDetectorTests: XCTestCase {

    // MARK: 纯判定分支

    func testDetectNilForHealthyImage() {
        XCTAssertNil(LowQualityDetector.detect(clarity: 0.8, overRatio: 0.0, underRatio: 0.0))
        // 恰在阈值上不算模糊（严格小于）。
        XCTAssertNil(LowQualityDetector.detect(
            clarity: AppConfig.lowQualityClarityThreshold,
            overRatio: AppConfig.lowQualityOverExposedRatioThreshold - 0.01,
            underRatio: 0
        ))
    }

    func testDetectBlurry() {
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.05, overRatio: 0, underRatio: 0), .blurry)
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.05, overRatio: nil, underRatio: nil), .blurry)
    }

    func testDetectExposureDominantOverBlur() {
        // 糊 + 过曝占比 ≥ 0.5 → 曝光主导。
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.05, overRatio: 0.6, underRatio: 0), .overexposed)
        // 糊 + 过曝占比不足主导 → 模糊主导。
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.05, overRatio: 0.35, underRatio: 0), .blurry)
        // 清晰但大面积过曝。
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.8, overRatio: 0.7, underRatio: 0), .overexposed)
    }

    func testDetectUnderExposure() {
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.8, overRatio: 0, underRatio: 0.6), .underexposed)
        // 糊 + 欠曝且无过曝 → 取欠曝（更难挽回）。
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.05, overRatio: 0, underRatio: 0.55), .underexposed)
    }

    func testMalformedFloatInputsDoNotCreateExposureCandidates() {
        XCTAssertNil(LowQualityDetector.detect(clarity: .nan, overRatio: .infinity, underRatio: .nan))
        XCTAssertEqual(LowQualityDetector.detect(clarity: 0.05, overRatio: .nan, underRatio: .infinity), .blurry)
    }

    func testPreselectableRedLines() {
        func candidate(favorite: Bool = false, edited: Bool = false, exempt: Bool = false) -> LowQualityCandidate {
            LowQualityCandidate(
                record: AssetRecord(
                    localIdentifier: "x", favorite: favorite, isEdited: edited,
                    mediaType: .image, pixelWidth: 1, pixelHeight: 1, duration: 0,
                    creationDate: nil, isScreenshot: false, isLivePhoto: false,
                    latitude: nil, longitude: nil
                ),
                kind: .blurry, clarity: 0.05, isNightExempt: exempt
            )
        }
        XCTAssertTrue(LowQualityDetector.preselectable(candidate()))
        XCTAssertFalse(LowQualityDetector.preselectable(candidate(favorite: true)), "红线：收藏永不预选")
        XCTAssertFalse(LowQualityDetector.preselectable(candidate(edited: true)), "红线：编辑过永不预选")
        XCTAssertFalse(LowQualityDetector.preselectable(candidate(exempt: true)), "红线 6：夜间豁免永不预选")
    }

    // MARK: 曝光占比 DSP

    func testExposureRatios() {
        var pixels = [UInt8](repeating: 128, count: 100)
        for index in 0..<60 { pixels[index] = 255 }   // 过曝样本
        for index in 60..<90 { pixels[index] = 0 }    // 欠曝样本

        XCTAssertEqual(ImageQualityDSP.overExposedRatio(grayPixels: pixels, width: 10, height: 10)!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(ImageQualityDSP.underExposedRatio(grayPixels: pixels, width: 10, height: 10)!, 0.3, accuracy: 1e-9)

        XCTAssertNil(ImageQualityDSP.overExposedRatio(grayPixels: [1, 2], width: 3, height: 1))
        XCTAssertNil(ImageQualityDSP.underExposedRatio(grayPixels: [], width: 0, height: 0))
    }

    // MARK: EXIF 提取（真实 JPEG 往返）

    func testEXIFExtractorReadsExposureTimeFromRealJPEG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ))
        let exifDict: [CFString: Any] = [kCGImagePropertyExifExposureTime: 2.0]
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exifDict]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let exif = try XCTUnwrap(EXIFExtractor.exif(fromEncodedImageData: output as Data))
        let exposure = (exif["ExposureTime"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertEqual(exposure, 2.0, accuracy: 0.001)
        XCTAssertTrue(NightWhitelist.isNightLongExposure(exif), "2 秒长曝应命中夜间白名单")
    }

    func testEXIFExtractorReturnsNilForNonImageData() {
        XCTAssertNil(EXIFExtractor.exif(fromEncodedImageData: Data("not-an-image".utf8)))
    }

    // MARK: 引擎集成

    /// PhotoKit 假件复用 ScanningEngineTests 的 FakePhotoLibraryService（同模块可见）。

    private func makeRecord(
        id: String,
        creationDate: Date?,
        favorite: Bool = false
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id, favorite: favorite, isEdited: false,
            mediaType: .image, pixelWidth: 100, pixelHeight: 100, duration: 0,
            creationDate: creationDate, isScreenshot: false, isLivePhoto: false,
            latitude: nil, longitude: nil
        )
    }

    /// 同步跑完引擎（与 ScanningEngineTests 同款屏障等待）。
    private func runAndWait(_ engine: ScanningEngine, workQueue: DispatchQueue) {
        engine.runFullScan { _, _ in }
        workQueue.sync { }
    }

    func testEngineLowQualityPassSnapshotAndDecisions() {
        let database = try! PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.lowquality")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // 六张互不成组 + 一对同哈希成组的重复图；时间拉开避免跨桶聚合。
        let records: [AssetRecord] = [
            makeRecord(id: "blurry", creationDate: base),
            makeRecord(id: "over", creationDate: base.addingTimeInterval(10 * 86_400)),
            makeRecord(id: "blurry-night", creationDate: base.addingTimeInterval(20 * 86_400)),
            makeRecord(id: "sharp", creationDate: base.addingTimeInterval(30 * 86_400)),
            makeRecord(id: "fav-blurry", creationDate: base.addingTimeInterval(40 * 86_400), favorite: true),
            makeRecord(id: "dup-a", creationDate: base.addingTimeInterval(50 * 86_400)),
            makeRecord(id: "dup-b", creationDate: base.addingTimeInterval(50 * 86_400 + 30)),
        ]
        let service = FakePhotoLibraryService(records: records)

        let lowClarityIds: Set<String> = ["blurry", "over", "blurry-night", "dup-a", "dup-b"]

        let engine = ScanningEngine(
            photoLibrary: service,
            database: database,
            store: store,
            imageDataLoader: { id in Data(id.utf8) },
            hashComputer: { data in
                let id = String(decoding: data, as: UTF8.self)
                return id.hasPrefix("dup") ? "abcdef0123456789" : nil
            },
            embeddingComputer: { _ in nil },
            featureAnalyzer: { data in
                let id = String(decoding: data, as: UTF8.self)
                return VisionAnalysisResult(
                    clarity: lowClarityIds.contains(id) ? 0.05 : 0.8,
                    aesthetics: 0.5, faceQuality: 0.5, saliency: 0.5
                )
            },
            exifReader: { data in
                let id = String(decoding: data, as: UTF8.self)
                return id == "blurry-night" ? ["ExposureTime": 2.0] : nil
            },
            exposureProbe: { data in
                let id = String(decoding: data, as: UTF8.self)
                return id == "over" ? (over: 0.6, under: 0.0) : (over: 0.0, under: 0.0)
            },
            workQueue: queue
        )

        runAndWait(engine, workQueue: queue)

        // 快照构成：组内资产（dup 对）与收藏让位/排除；清晰片不进。
        let snapshot = engine.lowQualityCandidates
        let snapshotIds = Set(snapshot.map { $0.record.localIdentifier })
        XCTAssertEqual(snapshotIds, Set(["blurry", "over", "blurry-night"]),
                       "实际：\(snapshot.map { ($0.record.localIdentifier, $0.kind, $0.isNightExempt) })")

        // 种类与豁免标。
        XCTAssertEqual(snapshot.first { $0.record.localIdentifier == "over" }?.kind, .overexposed)
        XCTAssertEqual(snapshot.first { $0.record.localIdentifier == "blurry" }?.kind, .blurry)
        XCTAssertEqual(snapshot.first { $0.record.localIdentifier == "blurry-night" }?.isNightExempt, true)

        // 裁决落库：非豁免项落 low_quality:*；豁免项与清晰片零裁决。
        XCTAssertEqual(database.decision(assetId: "blurry")?.verdict, .delete)
        XCTAssertTrue(database.decision(assetId: "blurry")!.reason.hasPrefix("low_quality:blurry"))
        XCTAssertEqual(database.decision(assetId: "over")?.reason, "low_quality:overexposed")
        XCTAssertNil(database.decision(assetId: "blurry-night"), "红线 6：豁免项不得落删除裁决")
        XCTAssertNil(database.decision(assetId: "sharp"))
        XCTAssertNil(database.decision(assetId: "fav-blurry"))
    }

    func testEngineRespectsUserOverrideOnRescanDecisions() {
        let database = try! PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.override")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let records = [
            makeRecord(id: "override-me", creationDate: base),
            makeRecord(id: "plain-blur", creationDate: base.addingTimeInterval(10 * 86_400)),
        ]
        database.upsert(asset: records[0], fetchedAt: base)
        database.upsert(asset: records[1], fetchedAt: base)
        database.setDecision(assetId: "override-me", verdict: .keep, reason: "user_override", decidedAt: base)

        let service = FakePhotoLibraryService(records: records)
        let engine = ScanningEngine(
            photoLibrary: service,
            database: database,
            store: store,
            imageDataLoader: { id in Data(id.utf8) },
            hashComputer: { _ in nil },
            embeddingComputer: { _ in nil },
            featureAnalyzer: { _ in
                VisionAnalysisResult(clarity: 0.02, aesthetics: 0.5, faceQuality: 0.5, saliency: 0.5)
            },
            exifReader: { _ in nil },
            exposureProbe: { _ in (over: 0, under: 0) },
            workQueue: queue
        )

        runAndWait(engine, workQueue: queue)

        // 用户亲手保留的资产不会在重扫时重新回到自动候选镜像。
        XCTAssertEqual(engine.lowQualityCandidates.count, 1)
        let overridden = database.decision(assetId: "override-me")
        XCTAssertEqual(overridden?.verdict, .keep, "user_override 不得被自动裁决覆盖")
        XCTAssertEqual(overridden?.reason, "user_override")
        XCTAssertEqual(database.decision(assetId: "plain-blur")?.verdict, .delete)
    }

    func testRemoveLowQualityCandidatesUpdatesMirror() {
        let database = try! PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.remove")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let records = [
            makeRecord(id: "a", creationDate: base),
            makeRecord(id: "b", creationDate: base.addingTimeInterval(86_400)),
        ]
        let engine = ScanningEngine(
            photoLibrary: FakePhotoLibraryService(records: records),
            database: database,
            store: store,
            imageDataLoader: { id in Data(id.utf8) },
            hashComputer: { _ in nil },
            embeddingComputer: { _ in nil },
            featureAnalyzer: { _ in
                VisionAnalysisResult(clarity: 0.02, aesthetics: 0.5, faceQuality: 0.5, saliency: 0.5)
            },
            exifReader: { _ in nil },
            exposureProbe: { _ in (over: 0, under: 0) },
            workQueue: queue
        )
        runAndWait(engine, workQueue: queue)
        XCTAssertEqual(engine.lowQualityCandidates.count, 2)

        engine.removeLowQualityCandidates(assetIds: ["a"])
        queue.sync { }   // 屏障等镜像更新
        XCTAssertEqual(engine.lowQualityCandidates.map { $0.record.localIdentifier }, ["b"])
    }
}
