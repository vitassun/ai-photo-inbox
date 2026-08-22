// MARK: - GroupScoringTests
// 职责：T09 单测——评分端到端纯逻辑集成（合成资产+合成特征 → 评分 →
//       SafetyRules 过滤）、冷启动 favoriteBoost 加倍、冗余度单调性、
//       分数信封落表、引擎 scoring 阶段冒烟。
// 任务卡：T09。CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class GroupScoringTests: XCTestCase {

    private func makeRecord(
        id: String,
        favorite: Bool = false,
        isEdited: Bool = false,
        seconds: TimeInterval = 0
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: favorite,
            isEdited: isEdited,
            mediaType: .image,
            pixelWidth: 100,
            pixelHeight: 100,
            duration: 0,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            isScreenshot: false,
            isLivePhoto: false,
            latitude: nil,
            longitude: nil
        )
    }

    private func features(clarity: Double = 0.5, aesthetics: Double = 0.5,
                          face: Double = 0.5, saliency: Double = 0.5) -> VisionAnalysisResult {
        VisionAnalysisResult(clarity: clarity, aesthetics: aesthetics, faceQuality: face, saliency: saliency)
    }

    private func group(_ records: [AssetRecord]) -> CandidateGroup {
        CandidateGroup(id: "g1", members: records, reason: "test")
    }

    // MARK: 端到端纯逻辑集成（验收标准第 1 条）

    func testRedLineMembersNeverAppearInPreselection() {
        let records = [
            makeRecord(id: "plain-1", seconds: 0),
            makeRecord(id: "plain-2", seconds: 30),
            makeRecord(id: "fav", favorite: true, seconds: 60),
            makeRecord(id: "edited", isEdited: true, seconds: 90),
        ]
        let features = [
            "plain-1": features(clarity: 0.9),
            "plain-2": features(clarity: 0.2),
            "fav": features(clarity: 0.2),
            "edited": features(clarity: 0.2),
        ]

        let scored = GroupScoring.score(
            group: group(records),
            featuresByID: features,
            hashByID: [:],
            embeddingByID: [:],
            hasUserData: false
        )

        // 全员有分、按分排序、Best Shot 是最高分者。
        XCTAssertEqual(scored.members.count, 4)
        XCTAssertEqual(scored.bestShot?.record.localIdentifier, "plain-1")

        // 红线：收藏过 / 编辑过的绝不出现在预选集；Best Shot 本身也不进。
        XCTAssertEqual(scored.preselectableIDs, ["plain-2"])
        XCTAssertFalse(scored.preselectableIDs.contains("fav"))
        XCTAssertFalse(scored.preselectableIDs.contains("edited"))
        XCTAssertFalse(scored.preselectableIDs.contains("plain-1"))
    }

    func testSingletonGroupHasEmptyPreselection() {
        // 组内唯一 → SafetyRules 红线 3 → 预选集必空。
        let scored = GroupScoring.score(
            group: group([makeRecord(id: "solo")]),
            featuresByID: ["solo": features()],
            hashByID: [:],
            embeddingByID: [:]
        )
        XCTAssertTrue(scored.preselectableIDs.isEmpty)
        XCTAssertEqual(scored.bestShot?.record.localIdentifier, "solo")
    }

    func testMissingFeaturesScoreWithNeutralValues() {
        // 无特征的资产按中性值参与（不崩、有分、可排序）。
        let scored = GroupScoring.score(
            group: group([makeRecord(id: "a"), makeRecord(id: "b", seconds: 30)]),
            featuresByID: [:],
            hashByID: [:],
            embeddingByID: [:]
        )
        XCTAssertEqual(scored.members.count, 2)
        XCTAssertEqual(scored.members[0].score, scored.members[1].score, "全中性同分")
    }

    // MARK: 冷启动 favoriteBoost 加倍（验收标准第 2 条前半）

    func testColdStartDoublesFavoriteBoost() {
        let favoriteInputs = KeepScore.Inputs(
            clarity: 0.5, faceQuality: 0.5, aesthetics: 0.5,
            saliency: 0.5, redundancy: 0, isFavorite: true
        )
        let plainInputs = KeepScore.Inputs(
            clarity: 0.5, faceQuality: 0.5, aesthetics: 0.5,
            saliency: 0.5, redundancy: 0, isFavorite: false
        )

        // 冷启动（hasUserData=false）：收藏加成分差 = 0.05×2 = 0.10。
        let coldDelta = KeepScore.score(inputs: favoriteInputs, hasUserData: false)
            - KeepScore.score(inputs: plainInputs, hasUserData: false)
        XCTAssertEqual(coldDelta, 0.10, accuracy: 0.0001)

        // 有历史：分差回落到 0.05。
        let warmDelta = KeepScore.score(inputs: favoriteInputs, hasUserData: true)
            - KeepScore.score(inputs: plainInputs, hasUserData: true)
        XCTAssertEqual(warmDelta, 0.05, accuracy: 0.0001)
    }

    // MARK: 冗余度单调性（验收标准第 2 条后半）

    func testHigherRedundancyYieldsLowerOrEqualScore() {
        var previous = Double.greatestFiniteMagnitude
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            let score = KeepScore.score(inputs: KeepScore.Inputs(
                clarity: 0.6, faceQuality: 0.5, aesthetics: 0.5,
                saliency: 0.5, redundancy: redundancy, isFavorite: false
            ))
            XCTAssertLessThanOrEqual(score, previous, "冗余度 \(redundancy) 分数应不升")
            previous = score
        }
    }

    func testRedundancyDerivedFromHashAndEmbeddingDistances() {
        let records = [makeRecord(id: "a"), makeRecord(id: "b", seconds: 30)]
        let identicalHash = String(repeating: "a", count: 16)

        // pHash 完全相同 → 冗余度 1。
        let hashRedundancy = GroupScoring.redundancy(
            of: records[0],
            in: group(records),
            hashByID: ["a": identicalHash, "b": identicalHash],
            embeddingByID: [:]
        )
        XCTAssertEqual(hashRedundancy, 1.0, accuracy: 0.0001)

        // embedding 正交 → 相似度 1 − √2/2。
        let embeddingRedundancy = GroupScoring.redundancy(
            of: records[0],
            in: group(records),
            hashByID: [:],
            embeddingByID: ["a": [1, 0], "b": [0, 1]]
        )
        XCTAssertEqual(embeddingRedundancy, 1 - (2.0).squareRoot() / 2, accuracy: 0.0001)

        // 无任何特征 → 0（不惩罚）。
        let none = GroupScoring.redundancy(
            of: records[0], in: group(records), hashByID: [:], embeddingByID: [:]
        )
        XCTAssertEqual(none, 0)
    }

    // MARK: 确定性

    func testScoringIsDeterministic() {
        let records = [
            makeRecord(id: "x", seconds: 0),
            makeRecord(id: "y", seconds: 30),
            makeRecord(id: "z", seconds: 60),
        ]
        let features = ["x": features(clarity: 0.7), "y": features(clarity: 0.7), "z": features(clarity: 0.4)]
        let first = GroupScoring.score(group: group(records), featuresByID: features, hashByID: [:], embeddingByID: [:])
        let second = GroupScoring.score(group: group(records), featuresByID: features, hashByID: [:], embeddingByID: [:])
        XCTAssertEqual(first, second)
        // 同分者按时间新→旧：y 在 x 前。
        XCTAssertEqual(first.members.map(\.record.localIdentifier), ["y", "x", "z"])
    }
}

// MARK: 分数信封与落表

final class FeatureScoresCodecTests: XCTestCase {

    func testScoresEnvelopeRoundTripAndKindDiscrimination() throws {
        let scores: [Double] = [0.25, 0.5, 0.75, 1.0]
        let encoded = FeaturePrintCodec.encodeScores(scores)
        XCTAssertEqual(FeaturePrintCodec.decodeScores(encoded)!, scores)
        XCTAssertNil(FeaturePrintCodec.decodeHash(encoded))
        XCTAssertNil(FeaturePrintCodec.decodeEmbedding(encoded))

        // 落表读回 + 版本过滤。
        let database = try PhotoLibraryDatabase.inMemory()
        database.upsert(asset: AssetRecord(
            localIdentifier: "s1", favorite: false, isEdited: false,
            mediaType: .image, pixelWidth: 1, pixelHeight: 1, duration: 0,
            creationDate: Date(timeIntervalSince1970: 0), isScreenshot: false,
            isLivePhoto: false, latitude: nil, longitude: nil
        ), fetchedAt: Date())
        database.upsertFeatureprint(
            assetId: "s1", data: encoded,
            featureVersion: ScanStateMachine.featureVersion, computedAt: Date()
        )
        XCTAssertEqual(database.allFeatureprintScores(featureVersion: ScanStateMachine.featureVersion)["s1"], scores)
        XCTAssertTrue(database.allFeatureprintHashes(featureVersion: ScanStateMachine.featureVersion).isEmpty)
    }
}

// MARK: 引擎 scoring 阶段冒烟

final class ScoringStageEngineTests: XCTestCase {

    func testEngineScoringProducesBestShotAndPreselection() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.scoring")

        // 4 张同刻同地照片（pHash 不可用 → 走 embedding 聚类成一组）。
        var records: [AssetRecord] = []
        for index in 0..<4 {
            records.append(AssetRecord(
                localIdentifier: "asset-\(index)",
                favorite: index == 3,          // 最后一张收藏 → 红线剔除
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
        let image = try SyntheticImage.jpeg(side: 64, seed: 7)

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            imageDataLoader: { _ in image },
            hashComputer: { _ in nil },
            embeddingComputer: { _ in [1.0, 0, 0] },   // 全同向量 → 一组 4 成员
            featureAnalyzer: { data in
                // 用字节校验和区分 clarity：不同图不同分；这里全同图 → 同分。
                VisionAnalysisResult(clarity: 0.5, aesthetics: 0.5, faceQuality: 0.5, saliency: 0.5)
            },
            hasUserData: false,
            workQueue: queue
        )

        engine.runFullScan { _, _ in }
        queue.sync { }

        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(engine.scoredGroups.count, 1)

        let scored = try XCTUnwrap(engine.scoredGroups.first)
        XCTAssertEqual(scored.members.count, 4)

        // 冷启动收藏加权翻倍：收藏的 asset-3 分数最高 → 成为 Best Shot
        //（这本身就是冷启动规则的集成级验证）。
        XCTAssertEqual(scored.bestShot?.record.localIdentifier, "asset-3")

        // 预选集：Best Shot（asset-3）与收藏者（同为 asset-3）都不进，其余三张按分排序。
        XCTAssertEqual(scored.preselectableIDs, ["asset-2", "asset-1", "asset-0"])

        // 分数已落表（信封 kind=3）。
        XCTAssertEqual(
            database.allFeatureprintScores(featureVersion: ScanStateMachine.featureVersion).count,
            4
        )
    }
}
