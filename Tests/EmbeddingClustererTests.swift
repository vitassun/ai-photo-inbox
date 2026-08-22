// MARK: - EmbeddingClustererTests
// 职责：T05 单测——归一化数学、阈值连通分量四类边界（单元素/全相似/全异/
//       链式相似）、确定性输出；特征信封编解码；embedding 落表与版本过滤；
//       引擎 hashing→embedding→clustering 全链冒烟（合成样本 + 真 Vision）。
// 任务卡：T05。CI 模拟器可验证。

import XCTest
import CoreGraphics
import UIKit
@testable import AIPhotoInbox

final class EmbeddingClustererTests: XCTestCase {

    // MARK: 归一化

    func testL2Normalization() {
        let vector = EmbeddingMath.normalized([3.0, 4.0])
        XCTAssertEqual(vector[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(vector[1], 0.8, accuracy: 0.0001)

        let norm = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 0.0001)

        // 零向量原样返回（无方向）。
        XCTAssertEqual(EmbeddingMath.normalized([0, 0, 0]), [0.0, 0.0, 0.0])
    }

    func testEuclideanRequiresSameDimension() {
        XCTAssertNil(EmbeddingMath.euclidean([1, 2], [1, 2, 3]))
        XCTAssertNil(EmbeddingMath.euclidean([], []))
        XCTAssertEqual(EmbeddingMath.euclidean([0, 1], [0, 1])!, 0, accuracy: 0.0001)
        XCTAssertEqual(EmbeddingMath.euclidean([1, 0], [0, 1])!, (2.0).squareRoot(), accuracy: 0.0001)
    }

    // MARK: 聚类四类边界（验收标准第 1 条）

    private func members(_ vectors: [[Double]]) -> [(id: String, vector: [Double])] {
        vectors.enumerated().map { (id: "m\($0.offset)", vector: $0.element) }
    }

    func testSingleElementYieldsSingletonComponent() {
        let components = EmbeddingClusterer.components(of: members([[1.0, 0], [0, 1]]))
        XCTAssertEqual(components.count, 2)   // 相距 √2 > 阈值，各自单例
    }

    func testAllSimilarMergeIntoOneComponent() {
        let components = EmbeddingClusterer.components(of: members([
            [1, 0, 0], [0.99, 0.1, 0], [0.98, 0.19, 0],
        ]))
        XCTAssertEqual(components.count, 1)
        XCTAssertEqual(components[0].count, 3)
    }

    func testAllDifferentStaySeparate() {
        let components = EmbeddingClusterer.components(of: members([
            [1, 0, 0], [0, 1, 0], [0, 0, 1],
        ]))
        XCTAssertEqual(components.count, 3)
    }

    func testChainSimilarityMergesTransitively() {
        // 链式：A~B（近）、B~C（近）、但 A 与 C 距离超阈值——并查集传递合并。
        let a: [Double] = [1.0, 0]
        let b: [Double] = [0.97, 0.24]      // 与 A 欧氏 ≈ 0.24
        let c: [Double] = [0.80, 0.60]      // 与 B 欧氏 ≈ 0.40；与 A 欧氏 ≈ 0.63（超阈值）
        let components = EmbeddingClusterer.components(of: [
            (id: "A", vector: a), (id: "B", vector: b), (id: "C", vector: c),
        ])
        XCTAssertEqual(components.count, 1)
        XCTAssertEqual(Set(components[0]), Set(["A", "B", "C"]))
    }

    func testDeterministicOutputAcrossRuns() {
        let input = members([
            [1, 0, 0], [0.95, 0.3, 0], [0, 1, 0], [0.02, 0.99, 0], [0, 0, 1],
        ])
        let first = EmbeddingClusterer.components(of: input)
        let second = EmbeddingClusterer.components(of: input)
        XCTAssertEqual(first, second, "同输入必须同输出")
        XCTAssertEqual(first.count, 3)
        let multiMember = first.filter { $0.count > 1 }.map { Set($0) }
        XCTAssertEqual(
            Set(multiMember.map { $0.sorted().joined(separator: "|") }),
            Set(["m0|m1", "m2|m3"])
        )
    }

    // MARK: 特征信封编解码

    func testFeaturePrintCodecHashRoundTrip() {
        let hex = String(repeating: "a1f0", count: 4)
        let encoded = FeaturePrintCodec.encodeHash(hex)
        XCTAssertEqual(FeaturePrintCodec.decodeHash(encoded), hex)
        XCTAssertNil(FeaturePrintCodec.decodeEmbedding(encoded), "hash 信封不能被当向量解出")
    }

    func testFeaturePrintCodecEmbeddingRoundTrip() {
        let vector: [Double] = [0.5, -1.25, 3.75, 0.0, Double.pi]
        let encoded = FeaturePrintCodec.encodeEmbedding(vector)
        let decoded = FeaturePrintCodec.decodeEmbedding(encoded)
        XCTAssertEqual(decoded?.count, vector.count)
        for (a, b) in zip(decoded ?? [], vector) {
            XCTAssertEqual(a, b, accuracy: 1e-12)
        }
        XCTAssertNil(FeaturePrintCodec.decodeHash(encoded), "embedding 信封不能被当哈希解出")
    }

    func testFeaturePrintCodecRejectsGarbage() {
        XCTAssertNil(FeaturePrintCodec.decodeHash(Data([9, 1, 2])))       // 未知标记
        XCTAssertNil(FeaturePrintCodec.decodeEmbedding(Data([2, 1, 2])))  // 长度不对齐
        XCTAssertNil(FeaturePrintCodec.decodeHash(Data()))
    }

    // MARK: embedding 落表与版本过滤（验收标准第 2 条）

    func testEmbeddingPersistenceAndVersionFilter() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        database.upsert(asset: makeRecord(id: "e1"), fetchedAt: Date())

        let vector = EmbeddingMath.normalized([3, 4])
        database.upsertFeatureprint(
            assetId: "e1",
            data: FeaturePrintCodec.encodeEmbedding(vector),
            featureVersion: 1,
            computedAt: Date()
        )

        XCTAssertEqual(database.allFeatureprintEmbeddings(featureVersion: 1)["e1"]?.count, 2)
        XCTAssertTrue(database.allFeatureprintEmbeddings(featureVersion: 2).isEmpty, "版本不符视为不存在")
        // 哈希读回不受 embedding 行干扰。
        XCTAssertTrue(database.allFeatureprintHashes(featureVersion: 1).isEmpty)
    }

    private func makeRecord(id: String) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: false,
            isEdited: false,
            mediaType: .image,
            pixelWidth: 100,
            pixelHeight: 100,
            duration: 0,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isScreenshot: false,
            isLivePhoto: false,
            latitude: nil,
            longitude: nil
        )
    }
}

/// 全链冒烟（验收标准第 3 条）：合成图 → hashing → embedding → clustering → done。
final class ScanningEngineFullChainTests: XCTestCase {

    func testSyntheticSamplesFlowThroughHashingEmbeddingClustering() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.fullchain")

        // 6 张同地同刻照片：0/1/2 共享同一张合成图（应聚一组），
        // 3/4/5 各自独享另一张合成图（彼此也相同→第二组）。
        var records: [AssetRecord] = []
        for index in 0..<6 {
            records.append(AssetRecord(
                localIdentifier: "asset-\(index)",
                favorite: false,
                isEdited: false,
                mediaType: .image,
                pixelWidth: 100,
                pixelHeight: 100,
                duration: 0,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 30)),
                isScreenshot: false,
                isLivePhoto: false,
                latitude: 31.0,
                longitude: 121.0
            ))
        }
        let fakeService = FakePhotoLibraryService(records: records)

        let imageA = try SyntheticImage.jpeg(side: 64, seed: 1)
        let imageB = try SyntheticImage.jpeg(side: 64, seed: 999)

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            imageDataLoader: { id in
                ["asset-0", "asset-1", "asset-2"].contains(id) ? imageA : imageB
            },
            hashComputer: { _ in nil },          // pHash 不可用 → 全部走 embedding 精比
            embeddingComputer: { data in
                // 位置加权校验和构造可区分向量：同图同向量、异图异向量
                // （不能用首字节——所有 JPEG 都以 0xFF 开头；加权把意外碰撞
                // 压到可忽略）。
                var checksum = 0
                for (index, byte) in data.prefix(8192).enumerated() {
                    checksum &+= Int(byte) * (index % 7 + 1)
                }
                return [Double(checksum), 1.0, 0.5]
            },
            workQueue: queue
        )

        engine.runFullScan { _, _ in }
        queue.sync { }

        XCTAssertEqual(engine.state, .done)

        let groups = engine.candidateGroups
        XCTAssertEqual(groups.count, 2, "两组合成图各成一候选组")
        let memberSets = groups.map { Set($0.memberIDs) }
        XCTAssertTrue(memberSets.contains(Set(["asset-0", "asset-1", "asset-2"])))
        XCTAssertTrue(memberSets.contains(Set(["asset-3", "asset-4", "asset-5"])))

        // embedding 已全部落表（信封编码）。
        let embeddings = database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion)
        XCTAssertEqual(embeddings.count, 6)

        // 真 Vision 冒烟：VNGenerateImageFeaturePrintRequest 在模拟器可用。
        let service = VisionAnalysisService()
        var visionVector: [Double]?
        let expectation = expectation(description: "vision embedding")
        service.computeEmbedding(imageData: imageA) { result in
            if case .success(let vector) = result { visionVector = vector }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
        XCTAssertGreaterThan(visionVector?.count ?? 0, 0, "Vision featureprint 应产出非空向量")

        // 归一化后欧氏距离落在 [0,2]。
        if let raw = visionVector {
            let normalized = EmbeddingMath.normalized(raw)
            let norm = (normalized.reduce(0) { $0 + $1 * $1 }).squareRoot()
            XCTAssertEqual(norm, 1.0, accuracy: 0.001)
        }
    }
}

enum SyntheticImage {
    /// 程序合成 JPEG（LCG 噪声图案，seed 决定内容）。
    static func jpeg(side: Int, seed: UInt64) throws -> Data {
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
}
