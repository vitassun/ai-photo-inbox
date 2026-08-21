// MARK: - ScanningEngineTests
// 职责：T03 扫描引擎单测——真实驱动 fetching 落表、占位阶段推进到 done、
//       GRDB store 上的断点续扫（杀进程模拟）、featureVersion 不符重置。
// 任务卡：T03。注入假数据源 + 内存库/临时磁盘库，CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

/// PhotoKit 服务假实现：返回固定记录，统计拉取次数；
/// onFetchBegin 钩子在引擎进入 fetching 阶段时同步触发（测试注入暂停时机）。
final class FakePhotoLibraryService: PhotoLibraryServiceProtocol {
    let records: [AssetRecord]
    private(set) var fetchAllCallCount = 0
    var onFetchBegin: (() -> Void)?

    init(records: [AssetRecord]) {
        self.records = records
    }

    var authorizationStatus: PhotoAuthorizationStatus { .authorized }

    func requestAccess(_ completion: @escaping (PhotoAuthorizationStatus) -> Void) {
        completion(.authorized)
    }

    func fetchAllAssets() -> [AssetRecord] {
        onFetchBegin?()
        fetchAllCallCount += 1
        return records
    }

    func fetchAssets(matching identifiers: [String]) -> [AssetRecord] {
        records.filter { identifiers.contains($0.localIdentifier) }
    }

    func requestDelete(of identifiers: [String], completion: @escaping (Bool, Error?) -> Void) {
        fatalError("删除流属 T10，本测试不应触达")
    }
}

final class ScanningEngineTests: XCTestCase {

    private func makeRecord(
        id: String,
        mediaType: AssetMediaType = .image,
        creationDate: Date? = nil
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: false,
            isEdited: false,
            mediaType: mediaType,
            pixelWidth: 100,
            pixelHeight: 100,
            duration: 0,
            creationDate: creationDate ?? Date(timeIntervalSince1970: 1_700_000_000),
            isScreenshot: false
        )
    }

    private func makeRecords(_ count: Int) -> [AssetRecord] {
        (0..<count).map { index in
            makeRecord(
                id: "asset-\(index)",
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
            )
        }
    }

    /// 同步跑完引擎：runFullScan 后在注入队列上做屏障等待。
    private func runAndWait(_ engine: ScanningEngine,
                            workQueue: DispatchQueue,
                            progressLog: ProgressLog) {
        engine.runFullScan { phase, progress in
            progressLog.append((phase, progress))
        }
        workQueue.sync { }   // 屏障：队列上排队的驱动块执行完毕才返回
    }

    private final class ProgressLog {
        private let lock = NSLock()
        private var entries: [(ScanPhase, Double)] = []
        func append(_ entry: (ScanPhase, Double)) {
            lock.lock(); entries.append(entry); lock.unlock()
        }
        func phases() -> [ScanPhase] {
            lock.lock(); defer { lock.unlock() }
            return entries.map { $0.0 }
        }
    }

    // MARK: 端到端：fetching 落表 → 占位推进 → done

    func testEndToEndPipelinePersistsAssetsAndReachesDone() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let fakeService = FakePhotoLibraryService(records: makeRecords(3))
        let queue = DispatchQueue(label: "test.engine.e2e")
        let log = ProgressLog()

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            workQueue: queue
        )
        runAndWait(engine, workQueue: queue, progressLog: log)

        // 终态与落表
        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(database.assetCount(), 3)

        // 进度回调覆盖各阶段且单调推进到 done
        let phases = log.phases()
        XCTAssertEqual(phases.first?.isActive, true, "首个回调应是活动阶段")
        XCTAssertEqual(phases.last, .done)
        XCTAssertTrue(phases.contains(.fetching))

        // 断点状态已持久化为 done（新实例恢复一致）
        let restoredMachine = ScanStateMachine(store: store)
        XCTAssertEqual(restoredMachine.phase, .done)

        // done 后重复 runFullScan 不重扫（状态机不推进）
        let callsBefore = fakeService.fetchAllCallCount
        runAndWait(engine, workQueue: queue, progressLog: log)
        XCTAssertEqual(fakeService.fetchAllCallCount, callsBefore)
    }

    // MARK: 杀进程模拟：写入 hashing/0.4 → 重建实例 → 恢复一致

    func testKillProcessSimulationRestoresPhaseAndProgressFromGRDB() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)

        // "进程 A"：推进两阶段到 hashing、进度 0.4，然后"被杀"（不再使用）。
        let machineA = ScanStateMachine(store: store)
        machineA.advance()   // idle → fetching
        machineA.advance()   // fetching → hashing
        machineA.setProgress(0.4)

        // "进程 B"：同一磁盘库重建实例，phase/progress 必须原样恢复。
        let machineB = ScanStateMachine(store: store)
        XCTAssertEqual(machineB.phase, .hashing)
        XCTAssertEqual(machineB.progress, 0.4, accuracy: 0.000001)
        XCTAssertTrue(machineB.isActive)
    }

    // MARK: 引擎级断点续扫：中途恢复从断点继续而非从头

    func testEngineResumesMidPipelineWithoutRefetching() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let fakeService = FakePhotoLibraryService(records: makeRecords(5))
        let queue = DispatchQueue(label: "test.engine.resume")

        // 预置断点：上一进程死在 embedding / 0.25。
        let previous = ScanStateMachine(store: store)
        previous.advance()   // fetching
        previous.advance()   // hashing
        previous.advance()   // embedding
        previous.setProgress(0.25)

        let log = ProgressLog()
        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: store,
            workQueue: queue
        )

        // 构造即恢复：不从头（阶段仍是 embedding，而非 idle/fetching）。
        XCTAssertEqual(engine.state, .embedding)

        runAndWait(engine, workQueue: queue, progressLog: log)
        XCTAssertEqual(engine.state, .done)

        // 关键契约：续扫不再进 fetching 重拉全库。
        XCTAssertEqual(fakeService.fetchAllCallCount, 0)

        // 恢复路径里没有 fetching 阶段的进度回调。
        XCTAssertFalse(log.phases().contains(.fetching))
    }

    // MARK: featureVersion 不符 → 重置 idle + 清脏特征

    func testFeatureVersionMismatchResetsToIdleAndPurgesDirtyPrints() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let encoder = JSONEncoder()

        // 预置旧版本脏状态与脏特征（特征行有外键，先落父资产行）。
        store.setString("0", forKey: "scan.featureVersion")
        store.setString(
            String(data: try encoder.encode(ScanPhase.hashing), encoding: .utf8)!,
            forKey: "scan.phase"
        )
        store.setString("0.5", forKey: "scan.progress")
        database.upsert(asset: makeRecord(id: "stale"), fetchedAt: Date())
        database.upsertFeatureprint(assetId: "stale", data: Data([9]), featureVersion: 0, computedAt: Date())
        XCTAssertEqual(database.featureprintCount(), 1, "前置断言：脏特征确实已入库")

        // 新实例：版本不符必须回到 idle（丢弃旧进度）。
        XCTAssertEqual(ScanStateMachine(store: store).phase, .idle)

        let fakeService = FakePhotoLibraryService(records: makeRecords(2))
        let queue = DispatchQueue(label: "test.engine.version")
        let engine = ScanningEngine(photoLibrary: fakeService, database: database, store: store, workQueue: queue)
        runAndWait(engine, workQueue: queue, progressLog: ProgressLog())

        // 从头重扫 + 脏特征被清（保留当前版本之外全部删除）。
        XCTAssertEqual(fakeService.fetchAllCallCount, 1)
        XCTAssertEqual(database.assetCount(), 2)
        XCTAssertEqual(database.featureprintCount(), 0)
        XCTAssertEqual(engine.state, .done)
    }

    // MARK: fetching 中途暂停：不得推进阶段，恢复后补齐尾部

    func testPauseDuringFetchingDoesNotAdvanceAndResumeCompletesTail() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let fakeService = FakePhotoLibraryService(records: makeRecords(10))
        let queue = DispatchQueue(label: "test.engine.pausefetch")
        let engine = ScanningEngine(photoLibrary: fakeService, database: database, store: store, workQueue: queue)

        // fetching 阶段内部（引擎循环的第一个资产边界）请求暂停。
        fakeService.onFetchBegin = { engine.pause() }

        engine.runFullScan { _, _ in }
        queue.sync { }

        // 关键契约：暂停生效、未推进过 fetching——残缺快照不得冒充全量进后续阶段。
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(database.assetCount(), 0)
        XCTAssertEqual(fakeService.fetchAllCallCount, 1)

        // 恢复后从 fetching 继续，补齐全部资产到 done。
        engine.resume()
        queue.sync { }
        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(database.assetCount(), 10)
        XCTAssertEqual(fakeService.fetchAllCallCount, 2, "续扫重新拉取一次补齐尾部")
    }

    // MARK: 暂停语义（非活动阶段暂停不崩溃；resume 未暂停时无害）

    func testPauseAndResumeOnInactiveStateAreHarmless() throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let fakeService = FakePhotoLibraryService(records: [])
        let queue = DispatchQueue(label: "test.engine.pause")

        let engine = ScanningEngine(
            photoLibrary: fakeService,
            database: database,
            store: GRDBKeyValueStore(database: database),
            workQueue: queue
        )
        engine.pause()
        queue.sync { }   // 让 pause 的标志写入落地
        engine.resume()  // 未处于 paused → 无操作
        queue.sync { }   // 排空队列

        XCTAssertEqual(engine.state, .idle)
    }
}
