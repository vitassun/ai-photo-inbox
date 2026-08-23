// MARK: - LargeMediaWiringTests
// 职责：T17 大媒体清理接线——估算字节落库、引擎 pass 快照（降序/红线/
//       组内让位/iCloud 未下载入列）、裁决落库与 user_override 尊重。
// 任务卡：T17。CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class LargeMediaWiringTests: XCTestCase {

    private func makeRecord(
        id: String,
        mediaType: AssetMediaType,
        width: Int,
        height: Int,
        duration: Double = 0,
        creationDate: Date?,
        favorite: Bool = false,
        locallyAvailable: Bool = true
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id, favorite: favorite, isEdited: false,
            mediaType: mediaType, pixelWidth: width, pixelHeight: height,
            duration: duration, creationDate: creationDate,
            isScreenshot: false, isLivePhoto: false,
            latitude: nil, longitude: nil,
            locallyAvailable: locallyAvailable
        )
    }

    private func runAndWait(_ engine: ScanningEngine, workQueue: DispatchQueue) {
        engine.runFullScan { _, _ in }
        workQueue.sync { }
    }

    func testEngineLargeMediaPassSnapshotOrderDecisionsAndPersistence() {
        let database = try! PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.largemedia")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // 体积档位（按 MediaSizeEstimator 系数）：
        //   vid-4k       3_750_000_000（4K·600s）
        //   override-vid 2_700_000_000（1080p·1200s，预置用户保留）
        //   icloud-vid   2_025_000_000（720p·1800s，iCloud 未下载）
        //   dup-a/dup-b  约 201.6MB 大图但同哈希成组 → 让位组流程
        //   img-small    远低于阈值
        let records: [AssetRecord] = [
            makeRecord(id: "vid-4k", mediaType: .video, width: 3840, height: 2160,
                       duration: 600, creationDate: base),
            makeRecord(id: "override-vid", mediaType: .video, width: 1920, height: 1080,
                       duration: 1200, creationDate: base.addingTimeInterval(86_400)),
            makeRecord(id: "icloud-vid", mediaType: .video, width: 1280, height: 720,
                       duration: 1800, creationDate: base.addingTimeInterval(2 * 86_400),
                       locallyAvailable: false),
            makeRecord(id: "img-small", mediaType: .image, width: 100, height: 100,
                       creationDate: base.addingTimeInterval(3 * 86_400)),
            makeRecord(id: "dup-a", mediaType: .image, width: 24000, height: 24000,
                       creationDate: base.addingTimeInterval(4 * 86_400)),
            makeRecord(id: "dup-b", mediaType: .image, width: 24000, height: 24000,
                       creationDate: base.addingTimeInterval(4 * 86_400 + 30)),
            makeRecord(id: "fav-vid", mediaType: .video, width: 3840, height: 2160,
                       duration: 600, creationDate: base.addingTimeInterval(5 * 86_400),
                       favorite: true),
        ]

        // 预置用户裁决：override-vid 用户已亲手保留。
        database.upsert(asset: records[1], fetchedAt: base)
        database.setDecision(assetId: "override-vid", verdict: .keep, reason: "user_override", decidedAt: base)

        let service = FakePhotoLibraryService(records: records)
        let engine = ScanningEngine(
            photoLibrary: service,
            database: database,
            store: store,
            // 加载器必须吐数据：hashComputer 靠解码 id 判定 dup 前缀，
            // 返回 nil 会跳过哈希计算 → 组认领断言失效。
            imageDataLoader: { id in Data(id.utf8) },
            hashComputer: { data in
                let id = String(decoding: data, as: UTF8.self)
                return id.hasPrefix("dup") ? "abcdef0123456789" : nil
            },
            embeddingComputer: { _ in nil },
            featureAnalyzer: { _ in
                VisionAnalysisResult(clarity: 0.8, aesthetics: 0.5, faceQuality: 0.5, saliency: 0.5)
            },
            screenshotOCR: { _ in nil },
            exifReader: { _ in nil },
            exposureProbe: { _ in (over: 0, under: 0) },
            workQueue: queue
        )

        runAndWait(engine, workQueue: queue)

        let snapshot = engine.largeMediaCandidates
        let ids = snapshot.map { $0.record.localIdentifier }
        XCTAssertEqual(Set(ids), Set(["vid-4k", "override-vid", "icloud-vid"]),
                       "实际：\(ids)")

        // 降序断言。
        XCTAssertEqual(ids.first, "vid-4k")
        XCTAssertEqual(ids, ["vid-4k", "override-vid", "icloud-vid"])

        // 裁决：非 keep 候选落 large_media；用户保留不被改写；小图零裁决。
        XCTAssertEqual(database.decision(assetId: "vid-4k")?.reason, "large_media")
        let overridden = database.decision(assetId: "override-vid")
        XCTAssertEqual(overridden?.verdict, .keep)
        XCTAssertEqual(overridden?.reason, "user_override")
        XCTAssertNil(database.decision(assetId: "img-small"))
        XCTAssertNil(database.decision(assetId: "fav-vid"), "收藏红线：不落删除裁决")

        // estimated_bytes 落库（fetching 阶段填充）。
        let expected = MediaSizeEstimator.estimatedBytes(for: records[0])
        let stored = database.row(forSQL: "SELECT estimated_bytes FROM assets WHERE local_identifier = 'vid-4k'")?["estimated_bytes"] as Int64?
        XCTAssertEqual(stored, expected)
    }
}
