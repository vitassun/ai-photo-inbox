// MARK: - GroupingTests
// 职责：T04 分组纯函数单测——汉明距离、地理聚类、pHash（合成图像）、
//       100 资产端到端小样本分组。
// 任务卡：T04。全部 CI 模拟器可验证，不依赖真机相册。

import XCTest
import CoreGraphics
import UIKit
@testable import AIPhotoInbox

final class GroupingTests: XCTestCase {

    // MARK: 汉明距离

    func testHammingDistanceBasics() {
        XCTAssertEqual(HashDistance.hamming(hexA: "ffffffff", hexB: "ffffffff"), 0)
        XCTAssertEqual(HashDistance.hamming(hexA: "00000000", hexB: "ffffffff"), 64)
        // a=1010 c=1100 差 2 位；b=1011 d=1101 差 2 位 → 合计 4。
        XCTAssertEqual(HashDistance.hamming(hexA: "ab", hexB: "cd"), 4)
        XCTAssertNil(HashDistance.hamming(hexA: "abc", hexB: "abcd"))   // 长度不等不可比
        XCTAssertNil(HashDistance.hamming(hexA: "", hexB: ""))
    }

    // MARK: 地理聚类

    private func point(_ id: String, _ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(id: id, latitude: lat, longitude: lon)
    }

    func testGeoClustererSamePointAndChainMerge() {
        // 同点重复出现 → 同簇。
        let same = [point("a", 31.0, 121.0), point("b", 31.0, 121.0)]
        XCTAssertEqual(GeoClusterer.cluster(same), [["a", "b"]])

        // 共线链式：每段 ~100m，半径 300m 内传递合并为一簇。
        let chain = [
            point("p1", 31.0000, 121.0000),
            point("p2", 31.0009, 121.0000),
            point("p3", 31.0018, 121.0000),
        ]
        let clustered = GeoClusterer.cluster(chain)
        XCTAssertEqual(clustered.count, 1)
        XCTAssertEqual(Set(clustered[0]), Set(["p1", "p2", "p3"]))
    }

    func testGeoClustererOutlierStaysSeparate() {
        let points = [
            point("near1", 31.0, 121.0),
            point("near2", 31.001, 121.0),
            point("far", 31.10, 121.0),   // ~11km 外
        ]
        let clustered = GeoClusterer.cluster(points)
        XCTAssertEqual(clustered.count, 2)

        // 单点与空输入边界。
        XCTAssertEqual(GeoClusterer.cluster([point("solo", 0, 0)]), [["solo"]])
        XCTAssertTrue(GeoClusterer.cluster([]).isEmpty)
    }

    func testHaversineKnownDistance() {
        // 赤道上经度差 1 度 ≈ 111.19 km。
        let meters = GeoClusterer.haversineMeters(point("a", 0, 0), point("b", 0, 1))
        XCTAssertEqual(meters, 111_195, accuracy: 500)
    }

    // MARK: pHash（程序合成图像）

    /// 确定性伪随机数（LCG），保证测试可复现。
    private func lcgSequence(seed: UInt64, count: Int) -> [UInt64] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    private func flatGray(_ value: UInt8, side: Int = 32) -> [UInt8] {
        Array(repeating: value, count: side * side)
    }

    func testPerceptualHashIdenticalInputProducesIdenticalHash() {
        let gray = flatGray(128)
        let hashA = PerceptualHash.hash(grayPixels: gray, width: 32, height: 32)
        let hashB = PerceptualHash.hash(grayPixels: gray, width: 32, height: 32)
        XCTAssertEqual(hashA, hashB)
        XCTAssertEqual(hashA?.count, 16)                       // 64 bit → 16 hex
        XCTAssertEqual(HashDistance.hamming(hexA: hashA!, hexB: hashB!), 0)
    }

    func testPerceptualHashSmallBrightnessShiftYieldsSmallDistance() {
        let base = (0..<32).map { row -> [UInt8] in
            (0..<32).map { col in UInt8(80 + ((row + col) % 4) * 20) }
        }.flatMap { $0 }
        let shifted = base.map { min(255, max(0, $0 < 200 ? $0 + 12 : $0)) }

        let hashBase = PerceptualHash.hash(grayPixels: base, width: 32, height: 32)!
        let hashShifted = PerceptualHash.hash(grayPixels: shifted, width: 32, height: 32)!
        let distance = HashDistance.hamming(hexA: hashBase, hexB: hashShifted)!
        XCTAssertLessThanOrEqual(distance, 16, "轻微亮度扰动不应大幅翻转哈希位，实际 \(distance)")
    }

    func testPerceptualHashNoiseDiffersStronglyFromFlat() {
        let noise = lcgSequence(seed: 42, count: 32 * 32).map { UInt8($0 % 256) }
        let hashNoise = PerceptualHash.hash(grayPixels: noise, width: 32, height: 32)!
        let hashFlat = PerceptualHash.hash(grayPixels: flatGray(128), width: 32, height: 32)!
        let distance = HashDistance.hamming(hexA: hashNoise, hexB: hashFlat)!
        XCTAssertGreaterThanOrEqual(distance, 20, "噪声图与平坦图的哈希应显著不同，实际 \(distance)")
    }

    func testPerceptualHashRejectsInvalidInput() {
        XCTAssertNil(PerceptualHash.hash(grayPixels: [], width: 0, height: 0))
        XCTAssertNil(PerceptualHash.hash(grayPixels: [1, 2, 3], width: 2, height: 2))
    }

    func testPerceptualHashFromEncodedJPEGIsStable() throws {
        // 合成 64×64 左黑右白图 → JPEG → 哈希；两次编码结果距离为 0。
        let side = 64
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<(side / 2) {
                let offset = (y * side + x) * 4
                rgba[offset] = 0; rgba[offset + 1] = 0; rgba[offset + 2] = 0; rgba[offset + 3] = 255
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &rgba,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let uiImage = UIImage(cgImage: image)
        let jpegData = try XCTUnwrap(uiImage.jpegData(compressionQuality: 0.9))

        let hashA = try XCTUnwrap(PerceptualHash.hash(fromEncodedImageData: jpegData))
        let hashB = try XCTUnwrap(PerceptualHash.hash(fromEncodedImageData: jpegData))
        XCTAssertEqual(hashA.count, 16)
        XCTAssertEqual(hashA, hashB)
    }

    // MARK: 端到端小样本：100 条合成资产

    private func makeGroupingRecord(
        id: String,
        seconds: TimeInterval,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: false,
            isEdited: false,
            mediaType: .image,
            pixelWidth: 100,
            pixelHeight: 100,
            duration: 0,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            isScreenshot: false,
            isLivePhoto: false,
            latitude: latitude,
            longitude: longitude
        )
    }

    func testCandidateGrouperHundredAssetSyntheticScenario() {
        var records: [AssetRecord] = []
        var hashes: [String: String] = [:]

        // 组 A：同地连拍 5 张（时间间隔 60s，坐标 ~百米内，哈希相同）。
        for index in 0..<5 {
            let id = "A\(index)"
            records.append(makeGroupingRecord(
                id: id, seconds: TimeInterval(index * 60),
                latitude: 31.2304 + Double(index) * 0.001, longitude: 121.4737
            ))
            hashes[id] = String(repeating: "a", count: 16)
        }
        // 组 B：同城另一场景 4 张（时间紧随 A 但地理隔开，哈希相同）。
        for index in 0..<4 {
            let id = "B\(index)"
            records.append(makeGroupingRecord(
                id: id, seconds: 300 + TimeInterval(index * 60),
                latitude: 39.9042, longitude: 116.4074
            ))
            hashes[id] = String(repeating: "b", count: 16)
        }
        // 组 C：3 张跨桶截图（时间 >30min 后，无坐标，哈希相同）。
        for index in 0..<3 {
            let id = "C\(index)"
            records.append(makeGroupingRecord(id: id, seconds: 7_200 + TimeInterval(index * 60)))
            hashes[id] = String(repeating: "c", count: 16)
        }
        // 其余 88 条散片：两两间隔 >1800s、无坐标、无哈希 → 不成组。
        for index in 0..<88 {
            let id = "S\(index)"
            records.append(makeGroupingRecord(id: id, seconds: 20_000 + TimeInterval(index * 3_600)))
        }
        XCTAssertEqual(records.count, 100)

        let groups = CandidateGrouper.groups(from: records, hashByID: hashes)

        XCTAssertEqual(groups.count, 3, "应恰好产出 A/B/C 三组")
        let memberSets = groups.map { Set($0.memberIDs) }
        XCTAssertTrue(memberSets.contains(Set((0..<5).map { "A\($0)" })))
        XCTAssertTrue(memberSets.contains(Set((0..<4).map { "B\($0)" })))
        XCTAssertTrue(memberSets.contains(Set((0..<3).map { "C\($0)" })))

        // 组内按时间升序（构造顺序即升序）。
        for group in groups where group.memberIDs.first == "A0" {
            XCTAssertEqual(group.memberIDs, ["A0", "A1", "A2", "A3", "A4"])
        }
    }

    func testCandidateGrouperSkipsRecordsWithoutCreationDate() {
        let undated = AssetRecord(
            localIdentifier: "x", favorite: false, isEdited: false,
            mediaType: .image, pixelWidth: 1, pixelHeight: 1, duration: 0,
            creationDate: nil, isScreenshot: false, isLivePhoto: false, latitude: nil, longitude: nil
        )
        let dated = makeGroupingRecord(id: "y", seconds: 0)
        XCTAssertTrue(CandidateGrouper.groups(from: [undated], hashByID: [:]).isEmpty)
        XCTAssertTrue(CandidateGrouper.groups(from: [undated, dated], hashByID: ["y": String(repeating: "d", count: 16)]).isEmpty)
    }

    // MARK: 引擎 hashing 阶段集成（假图像源 + 真 pHash）

    private func makeRecord(
        id: String,
        creationDate: Date,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: false,
            isEdited: false,
            mediaType: .image,
            pixelWidth: 100,
            pixelHeight: 100,
            duration: 0,
            creationDate: creationDate,
            isScreenshot: false,
            isLivePhoto: false,
            latitude: latitude,
            longitude: longitude
        )
    }

    func testEngineHashingStageProducesGroupsAndFeatureprints() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.hashing")

        // 6 张同一连拍：前 3 张有图像数据且字节相同 → 应聚成一组。
        var records: [AssetRecord] = []
        for index in 0..<6 {
            records.append(makeRecord(
                id: "asset-\(index)",
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 30)),
                latitude: 31.0, longitude: 121.0
            ))
        }
        let fakeService = FakePhotoLibraryService(records: records)

        let side = 64
        var rgba = [UInt8](repeating: 200, count: side * side * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let sharedJPEG = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.9))

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            imageDataLoader: { id in ["asset-0", "asset-1", "asset-2"].contains(id) ? sharedJPEG : nil },
            hashComputer: { PerceptualHash.hash(fromEncodedImageData: $0) },
            workQueue: queue
        )

        engine.runFullScan { _, _ in }
        queue.sync { }

        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(database.featureprintCount(), 3, "有图像数据的 3 个资产应落 featureprints")

        let groups = engine.candidateGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.memberIDs, ["asset-0", "asset-1", "asset-2"])
    }
}
