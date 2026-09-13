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
            featureVersion: ScanStateMachine.featureVersion,
            computedAt: Date()
        )

        XCTAssertEqual(database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion)["e1"]?.count, 2)
        XCTAssertTrue(
            database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion + 1).isEmpty,
            "版本不符视为不存在"
        )
        // 哈希读回不受 embedding 行干扰。
        XCTAssertTrue(database.allFeatureprintHashes(featureVersion: ScanStateMachine.featureVersion).isEmpty)
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
                // 双混叠哈希构造可区分向量：同图同向量；异图的两个高方差
                // 维度使归一化后的方向差异远超阈值。（首字节全是 0xFF 不可用；
                // 单一大数维度归一化后会贴轴导致异图也"相似"。）
                var hash1 = 5381
                var hash2 = 52711
                for (index, byte) in data.prefix(8192).enumerated() {
                    hash1 = (hash1 &* 33 &+ Int(byte)) % 1_000_003
                    if index % 2 == 0 {
                        hash2 = (hash2 &* 31 &+ Int(byte)) % 1_000_003
                    }
                }
                return [Double(hash1), Double(hash2), 1.0]
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

    /// 验收（T05 补充）：embedding 精比路径同样必须做到"一个资产只属于一个最终组"。
    ///
    /// 组装是**跨批次累加式**的：每批在已有候选组上追加本批的连通分量，
    /// 后续批次看到的 `claimed` 集合更大。这条测试让同一资产在多个时间×地理
    /// 单元间具有相似关系（单元切分只限制比较范围，不决定最终归属），
    /// 断言不产生重复成员、且成组数与一次性全量重算一致。
    func testEmbeddingPathNeverProducesDuplicateMembersAcrossBatches() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.embedding.dedup")

        // 12 张同图照片，时间跨越多个时间桶 → 至少 2 个单元，必然跨批组装。
        // 缩小批大小以确保真的分批（每批只处理 1 个单元）。
        let assetCount = 12
        var records: [AssetRecord] = []
        for index in 0..<assetCount {
            records.append(AssetRecord(
                localIdentifier: "asset-\(index)",
                favorite: false,
                isEdited: false,
                mediaType: .image,
                pixelWidth: 100,
                pixelHeight: 100,
                duration: 0,
                // 每张间隔 10 小时：远超 AppConfig.timeGapThreshold，制造多个时间桶。
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 36_000)),
                isScreenshot: false,
                isLivePhoto: false,
                latitude: 31.0,
                longitude: 121.0
            ))
        }
        let fakeService = FakePhotoLibraryService(records: records)

        // 全部同图 → embedding 完全相同 → 每个单元内都是完整连通分量。
        let sharedImage = try SyntheticImage.jpeg(side: 64, seed: 7)

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            imageDataLoader: { _ in sharedImage },
            hashComputer: { _ in nil },          // pHash 不可用 → 强制走 embedding 路径
            embeddingComputer: { data in
                var hash1 = 5381
                var hash2 = 52711
                for (index, byte) in data.prefix(8192).enumerated() {
                    hash1 = (hash1 &* 33 &+ Int(byte)) % 1_000_003
                    if index % 2 == 0 {
                        hash2 = (hash2 &* 31 &+ Int(byte)) % 1_000_003
                    }
                }
                return [Double(hash1), Double(hash2), 1.0]
            },
            workQueue: queue,
            batchSizeOverride: 1                // 每批 1 个单元 → 强制跨批累加
        )

        engine.runFullScan { _, _ in }
        queue.sync { }

        XCTAssertEqual(engine.state, .done)

        let groups = engine.candidateGroups
        let allMemberIDs = groups.flatMap(\.memberIDs)

        // 核心断言：任何资产不得出现在两个最终组里。
        XCTAssertEqual(
            allMemberIDs.count, Set(allMemberIDs).count,
            "embedding 路径不得产生重复成员：\(allMemberIDs)"
        )

        // 每个资产的归属唯一，且总数守恒。
        XCTAssertEqual(Set(allMemberIDs).count, assetCount, "所有相似资产都应被归组")

        // 组内不得重复成员（同一组内同一 id 出现两次）。
        for group in groups {
            XCTAssertEqual(
                group.memberIDs.count, Set(group.memberIDs).count,
                "组 \(group.id) 内部出现重复成员：\(group.memberIDs)"
            )
        }

        // 候选组 id 必须确定且唯一。
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count, "候选组 id 必须唯一")
    }

    /// 验收（T05 补充）：embedding 路径的输出必须与记录输入顺序无关。
    /// 打乱 `fetchedRecords` 顺序后重建引擎，最终分组成员集合应完全一致。
    func testEmbeddingPathIsOrderIndependent() throws {
        let assetCount = 9

        func makeRecords(reversed: Bool) -> [AssetRecord] {
            var records: [AssetRecord] = []
            for index in 0..<assetCount {
                records.append(AssetRecord(
                    localIdentifier: "asset-\(index)",
                    favorite: false,
                    isEdited: false,
                    mediaType: .image,
                    pixelWidth: 100,
                    pixelHeight: 100,
                    duration: 0,
                    creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 36_000)),
                    isScreenshot: false,
                    isLivePhoto: false,
                    latitude: 31.0,
                    longitude: 121.0
                ))
            }
            return reversed ? records.reversed() : records
        }

        func run(reversed: Bool) throws -> Set<Set<String>> {
            let database = try PhotoLibraryDatabase.inMemory()
            let store = GRDBKeyValueStore(database: database)
            let queue = DispatchQueue(label: "test.engine.embedding.order.\(reversed)")
            let image = try SyntheticImage.jpeg(side: 64, seed: 11)

            let engine = ScanningEngine(
                photoLibrary: FakePhotoLibraryService(records: makeRecords(reversed: reversed)),
                database: database,
                store: store,
                imageDataLoader: { _ in image },
                hashComputer: { _ in nil },
                embeddingComputer: { data in
                    var hash1 = 5381
                    var hash2 = 52711
                    for (index, byte) in data.prefix(8192).enumerated() {
                        hash1 = (hash1 &* 33 &+ Int(byte)) % 1_000_003
                        if index % 2 == 0 {
                            hash2 = (hash2 &* 31 &+ Int(byte)) % 1_000_003
                        }
                    }
                    return [Double(hash1), Double(hash2), 1.0]
                },
                workQueue: queue,
                batchSizeOverride: 1
            )
            engine.runFullScan { _, _ in }
            queue.sync { }
            XCTAssertEqual(engine.state, .done)
            return Set(engine.candidateGroups.map { Set($0.memberIDs) })
        }

        let forward = try run(reversed: false)
        let backward = try run(reversed: true)
        XCTAssertEqual(forward, backward, "embedding 组装的最终成员集合必须与输入顺序无关")
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
