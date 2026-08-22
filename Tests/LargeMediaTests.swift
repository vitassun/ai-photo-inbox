// MARK: - LargeMediaTests
// 职责：T07 单测——体积估算模型标定区间与极端值钳制、LivePhoto 配对分类、
//       大媒体候选过滤与排序。
// 任务卡：T07。全部纯函数，CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class LargeMediaTests: XCTestCase {

    private func makeRecord(
        id: String = "m1",
        mediaType: AssetMediaType = .image,
        width: Int = 4000,
        height: Int = 3000,
        duration: Double = 0,
        favorite: Bool = false,
        isEdited: Bool = false,
        isLivePhoto: Bool = false
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: favorite,
            isEdited: isEdited,
            mediaType: mediaType,
            pixelWidth: width,
            pixelHeight: height,
            duration: duration,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isScreenshot: false,
            isLivePhoto: isLivePhoto,
            latitude: nil,
            longitude: nil
        )
    }

    // MARK: 估算模型（验收：标定值 + 极端值钳制）

    func testPhotoEstimationWithinCalibratedRange() throws {
        // 期望值是独立硬编码字面量（12M 像素 × 0.35 bytes/px），把系数钉死到具体值——
        // 系数若被误改（如 0.35→3.5、漏除 8）立即失败。真实分布校准属真机验收项。
        let bytes = try XCTUnwrap(MediaSizeEstimator.estimatedBytes(for: makeRecord()))
        XCTAssertEqual(Double(bytes), 12_000_000 * 0.35, accuracy: 1)
    }

    func testLivePhotoCountsVideoComponent() {
        let plain = MediaSizeEstimator.estimatedBytes(for: makeRecord())!
        let live = MediaSizeEstimator.estimatedBytes(for: makeRecord(isLivePhoto: true))!
        XCTAssertEqual(live, plain * 2, "Live Photo 视频组件按同量级双倍估算")
    }

    func testVideoEstimationByTierAndDuration() throws {
        // 4K 档：60s × 50Mbps / 8 = 375MB。
        let fourK = try XCTUnwrap(MediaSizeEstimator.estimatedBytes(
            for: makeRecord(id: "v", mediaType: .video, width: 3840, height: 2160, duration: 60)
        ))
        XCTAssertEqual(Double(fourK), 60.0 * 50_000_000 / 8, accuracy: 1)

        // 1080p 档：30s × 18Mbps / 8 = 67.5MB。
        let hd = try XCTUnwrap(MediaSizeEstimator.estimatedBytes(
            for: makeRecord(id: "v2", mediaType: .video, width: 1920, height: 1080, duration: 30)
        ))
        XCTAssertEqual(Double(hd), 30.0 * 18_000_000 / 8, accuracy: 1)
    }

    func testExtremeValuesAreClampedNotCrashing() {
        // 0 尺寸照片 → nil（不可估）。
        XCTAssertNil(MediaSizeEstimator.estimatedBytes(for: makeRecord(width: 0, height: 0)))
        // 未知类型 → nil。
        XCTAssertNil(MediaSizeEstimator.estimatedBytes(for: makeRecord(mediaType: .unknown)))
        // 超长视频钳制在 4 小时内。
        let clamped = MediaSizeEstimator.estimatedBytes(
            for: makeRecord(id: "v3", mediaType: .video, width: 3840, height: 2160, duration: 100 * 3600)
        )!
        let cap = Int64(4.0 * 3600 * 50_000_000 / 8)
        XCTAssertLessThanOrEqual(clamped, cap)
        // 零时长视频 → 0 字节（有定义）。
        XCTAssertEqual(
            MediaSizeEstimator.estimatedBytes(
                for: makeRecord(id: "v4", mediaType: .video, width: 1920, height: 1080, duration: 0)
            ),
            0
        )
    }

    func testDisplayBytesUsesHumanUnits() {
        XCTAssertEqual(MediaSizeEstimator.displayBytes(nil), "约未知")
        XCTAssertTrue(MediaSizeEstimator.displayBytes(5_000_000_000).contains("GB"))
        XCTAssertTrue(MediaSizeEstimator.displayBytes(50_000_000).contains("MB"))
        XCTAssertTrue(MediaSizeEstimator.displayBytes(50_000).contains("KB"))
    }

    // MARK: LivePhoto 配对（验收：成对映射 + 孤儿兜底）

    func testPairingClassification() {
        let classification = LivePhotoPairing.classify(componentsByAsset: [
            "pair1": [.photo, .pairedVideo],
            "pair2": [.pairedVideo, .photo],
            "orphanV": [.pairedVideo],
            "orphanP": [.photo],
            "notLive": [],
        ])
        XCTAssertEqual(classification.completePairs, ["pair1", "pair2"])
        XCTAssertEqual(classification.orphanVideos, ["orphanV"])
        XCTAssertEqual(classification.orphanPhotos, ["orphanP"])
    }

    func testPairingEmptyInput() {
        let classification = LivePhotoPairing.classify(componentsByAsset: [:])
        XCTAssertTrue(classification.completePairs.isEmpty)
        XCTAssertTrue(classification.orphanVideos.isEmpty)
        XCTAssertTrue(classification.orphanPhotos.isEmpty)
    }

    // MARK: 大媒体过滤（验收：打标排序正确 + 红线豁免剔除）

    func testLargeMediaCandidatesSortedAndRedLinesHonored() throws {
        let records = [
            makeRecord(id: "big-video", mediaType: .video, width: 3840, height: 2160, duration: 600),   // 3.75GB
            makeRecord(id: "small-video", mediaType: .video, width: 1920, height: 1080, duration: 30),  // ~67MB < 阈值
            makeRecord(id: "fav-video", mediaType: .video, width: 3840, height: 2160, duration: 600, favorite: true),
            makeRecord(id: "edited-video", mediaType: .video, width: 3840, height: 2160, duration: 600, isEdited: true),
            makeRecord(id: "grouped-video", mediaType: .video, width: 3840, height: 2160, duration: 120),
        ]

        let candidates = LargeMediaFilter.candidates(
            from: records,
            idsInCandidateGroups: ["grouped-video"]
        )

        // 收藏/编辑/已入组的全部剔除；仅剩未打标的大视频，按体积降序。
        XCTAssertEqual(candidates.map(\.record.localIdentifier), ["big-video"])
        XCTAssertEqual(try XCTUnwrap(candidates.first).estimatedBytes,
                       Int64(600.0 * 50_000_000 / 8))
    }

    func testLargeMediaSortedDescendingByEstimatedBytes() {
        // 多个幸存者才能真正验证降序排序（单幸存者对任意排序恒真）。
        let records = [
            makeRecord(id: "mid", mediaType: .video, width: 3840, height: 2160, duration: 120),  // 750MB
            makeRecord(id: "big", mediaType: .video, width: 3840, height: 2160, duration: 600),  // 3.75GB
            makeRecord(id: "tiny", mediaType: .image),                                           // ~4MB，低于阈值
        ]
        let candidates = LargeMediaFilter.candidates(from: records)
        XCTAssertEqual(candidates.map(\.record.localIdentifier), ["big", "mid"])
        XCTAssertGreaterThan(candidates[0].estimatedBytes, candidates[1].estimatedBytes)
    }

    func testLargeMediaDefaultThresholdExcludesOrdinaryPhotos() {
        // 12MP 照片 ≈ 4.2MB，远低于 200MB 默认阈值 → 不打标。
        let candidates = LargeMediaFilter.candidates(from: [makeRecord()])
        XCTAssertTrue(candidates.isEmpty)
    }
}
