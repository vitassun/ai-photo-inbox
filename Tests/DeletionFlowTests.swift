// MARK: - DeletionFlowTests
// 职责：T10 单测——调用方契约（只有 SafetyRules 过滤后的 id 进删除通道）、
//       分批切分与顺序、批次失败续传语义、verdicts 落库、组视图刷新。
// 任务卡：T10。CI 模拟器可验证（真机确认框行为另测）。

import XCTest
@testable import AIPhotoInbox

final class DeletionFlowTests: XCTestCase {

    private func makeRecord(id: String, seconds: TimeInterval = 0) -> AssetRecord {
        AssetRecord(
            localIdentifier: id, favorite: false, isEdited: false,
            mediaType: .image, pixelWidth: 100, pixelHeight: 100,
            duration: 0, creationDate: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            isScreenshot: false, isLivePhoto: false, latitude: nil, longitude: nil
        )
    }

    // MARK: 调用方契约：只有过 SafetyRules 的集合进删除通道

    func testPendingDeletionIDsOnlyContainsSafetyFilteredMembers() {
        // 构造评分视图：fav/edited 在 T09 已被 SafetyRules 剔除出 preselectableIDs。
        let record = { (id: String) in self.makeRecord(id: id) }
        let scored = ScoredGroup(
            groupID: "g1",
            reason: "test",
            members: [
                ScoredMember(record: record("best"), score: 0.9, isBestShot: true),
                ScoredMember(record: record("low-1"), score: 0.2, isBestShot: false),
                ScoredMember(record: record("low-2"), score: 0.1, isBestShot: false),
            ],
            preselectableIDs: ["low-2", "low-1"]
        )

        let ids = DeletionFlow.pendingDeletionIDs(from: [scored])
        XCTAssertEqual(ids, ["low-2", "low-1"], "契约：preselectableIDs 即全部可删集")
        XCTAssertFalse(ids.contains("best"), "Best Shot 永不进删除通道")

        // 跨组去重保持确定性。
        let duplicated = ScoredGroup(
            groupID: "g2", reason: "test",
            members: [ScoredMember(record: record("low-1"), score: 0.3, isBestShot: false)],
            preselectableIDs: ["low-1", "extra"]
        )
        XCTAssertEqual(DeletionFlow.pendingDeletionIDs(from: [scored, duplicated]), ["low-2", "low-1", "extra"])
    }

    /// mock 协议层断言：把汇总结果喂给 requestDelete 时，mock 收到的
    /// 集合与 SafetyRules 过滤产物完全一致。
    func testMockServiceReceivesExactlyTheFilteredSet() {
        final class MockDeletionService: PhotoLibraryServiceProtocol {
            private(set) var requestedDeletes: [[String]] = []
            var authorizationStatus: PhotoAuthorizationStatus { .authorized }
            func requestAccess(_ completion: @escaping (PhotoAuthorizationStatus) -> Void) { completion(.authorized) }
            func fetchAllAssets() -> [AssetRecord] { [] }
            func fetchAssets(matching identifiers: [String]) -> [AssetRecord] { [] }
            func requestDelete(of identifiers: [String], completion: @escaping (Bool, Error?) -> Void) {
                requestedDeletes.append(identifiers)
                completion(true, nil)
            }
        }

        let scored = ScoredGroup(
            groupID: "g", reason: "t",
            members: [
                ScoredMember(record: makeRecord(id: "keep"), score: 0.9, isBestShot: true),
                ScoredMember(record: makeRecord(id: "drop"), score: 0.1, isBestShot: false),
            ],
            preselectableIDs: ["drop"]
        )

        let mock = MockDeletionService()
        let pending = DeletionFlow.pendingDeletionIDs(from: [scored])
        mock.requestDelete(of: pending) { _, _ in }
        XCTAssertEqual(mock.requestedDeletes, [["drop"]], "mock 收到的必须恰好是过滤后集合")
    }

    // MARK: 分批逻辑

    func testBatchingSplitsStableOrder() {
        let ids = (0..<450).map { "id-\($0)" }
        let batches = DeletionFlow.batches(of: ids)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].count, 200)
        XCTAssertEqual(batches[1].count, 200)
        XCTAssertEqual(batches[2].count, 50)
        XCTAssertEqual(batches.flatMap { $0 }, ids, "切分不丢序")

        XCTAssertTrue(DeletionFlow.batches(of: []).isEmpty)
        XCTAssertEqual(DeletionFlow.batches(of: ["only"]), [["only"]])
    }

    func testBatchFailureStopsLaterBatches() {
        var executedBatches: [[String]] = []
        let ids = (0..<5).map { "id-\($0)" }   // 上限 2 → 批次 [0,1] [2,3] [4]

        struct Boom: Error {}
        let error = DeletionFlow.runBatches(ids, maxBatchSize: 2) { batch, index in
            executedBatches.append(batch)
            if index == 1 { throw Boom() }
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(executedBatches.count, 2, "第二批失败后第三批不得执行")
        XCTAssertEqual(executedBatches[0], ["id-0", "id-1"])
        XCTAssertEqual(executedBatches[1], ["id-2", "id-3"])

        // 全部成功 → nil，且回调逐批上报。
        var completed: [[String]] = []
        let ok = DeletionFlow.runBatches(
            ids, maxBatchSize: 2,
            perform: { _, _ in },
            onBatchCompleted: { batch, _ in completed.append(batch) }
        )
        XCTAssertNil(ok)
        XCTAssertEqual(completed.count, 3)
    }

    // MARK: verdicts 落库 + 组视图刷新

    func testMarkDeletedWritesVerdictsForSurvivingRows() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        database.upsert(asset: makeRecord(id: "gone"), fetchedAt: Date())
        database.markDeleted(assetIds: ["gone"])

        let decision = try XCTUnwrap(database.decision(assetId: "gone"))
        XCTAssertEqual(decision.verdict, .delete)
        XCTAssertEqual(decision.reason, "user_approved_system_confirm")
    }

    func testEnginePurgeDeletedFromViewsRemovesMembersAndDissolvesSmallGroups() throws {
        // 真引擎路径：跑完全链得到候选组/评分视图，然后模拟删除批准后的刷新。
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let queue = DispatchQueue(label: "test.engine.purge")

        var records: [AssetRecord] = []
        for index in 0..<3 {
            records.append(AssetRecord(
                localIdentifier: "asset-\(index)",
                favorite: false, isEdited: false, mediaType: .image,
                pixelWidth: 100, pixelHeight: 100, duration: 0,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 30)),
                isScreenshot: false, isLivePhoto: false,
                latitude: 31.0, longitude: 121.0
            ))
        }
        let fakeService = FakePhotoLibraryService(records: records)
        let image = try SyntheticImage.jpeg(side: 64, seed: 5)

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            imageDataLoader: { _ in image },
            hashComputer: { _ in nil },
            embeddingComputer: { _ in [1.0, 0, 0] },
            workQueue: queue
        )
        engine.runFullScan { _, _ in }
        queue.sync { }
        XCTAssertEqual(engine.candidateGroups.count, 1)

        // 删除 asset-2（假设用户在系统确认框批准了它）→ verdicts + 视图刷新。
        let deletedID = "asset-2"
        database.markDeleted(assetIds: [deletedID])
        let purged = expectation(description: "purge done")
        engine.purgeDeletedFromViews(assetIds: [deletedID]) {
            purged.fulfill()
        }
        wait(for: [purged], timeout: 5)
        queue.sync { }

        XCTAssertEqual(engine.candidateGroups.first?.memberIDs, ["asset-0", "asset-1"], "已删成员移出候选组")
        let scored = try XCTUnwrap(engine.scoredGroups.first)
        XCTAssertFalse(scored.members.contains { $0.record.localIdentifier == deletedID })
        XCTAssertFalse(scored.preselectableIDs.contains(deletedID), "已删 id 不再出现在预选集")
        XCTAssertNotNil(scored.bestShot, "剩余 ≥2 成员，Best Shot 标记保留")
    }
}
