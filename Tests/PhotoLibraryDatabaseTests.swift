// MARK: - PhotoLibraryDatabaseTests
// 职责：T03 持久化层单测——五张表建库迁移、逐字段插读断言、upsert 语义、
//       featureVersion 脏数据清理、schema 升级路径、GRDB 版 KeyValueStore。
// 任务卡：T03。全部跑在匿名内存库上，CI 模拟器可验证。

import XCTest
import GRDB
@testable import AIPhotoInbox

final class PhotoLibraryDatabaseTests: XCTestCase {

    private func makeDatabase() throws -> PhotoLibraryDatabase {
        try PhotoLibraryDatabase.inMemory()
    }

    private func makeAsset(
        id: String = "asset-1",
        favorite: Bool = true,
        isEdited: Bool = false,
        mediaType: AssetMediaType = .image,
        width: Int = 1920,
        height: Int = 1080,
        duration: Double = 0,
        creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        isScreenshot: Bool = false,
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
            creationDate: creationDate,
            isScreenshot: isScreenshot,
            isLivePhoto: isLivePhoto,
            latitude: nil,
            longitude: nil
        )
    }

    // MARK: assets 表：建库 → 插入 → 读回逐字段断言

    func testAssetsTableRoundTripAllFields() throws {
        let database = try makeDatabase()
        let creation = Date(timeIntervalSince1970: 1_700_000_123)
        database.upsert(
            asset: makeAsset(
                id: "A", favorite: true, isEdited: false, mediaType: .video,
                width: 3840, height: 2160, duration: 12.5,
                creationDate: creation, isScreenshot: false
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            locallyAvailable: false
        )

        let row = try XCTUnwrap(database.row(forSQL: "SELECT * FROM assets WHERE local_identifier = 'A'"))
        XCTAssertEqual(row["local_identifier"], "A")
        XCTAssertEqual(row["favorite"], true)
        XCTAssertEqual(row["is_edited"], false)
        XCTAssertEqual(row["media_type"], "video")
        XCTAssertEqual(row["pixel_width"], 3840)
        XCTAssertEqual(row["pixel_height"], 2160)
        XCTAssertEqual(row["duration_seconds"] as Double?, 12.5)
        XCTAssertEqual(row["creation_date"] as Double?, creation.timeIntervalSince1970)
        XCTAssertEqual(row["is_screenshot"], false)
        XCTAssertEqual(row["locally_available"], false)   // iCloud 未下载
        XCTAssertNil(row["burst_id"])                     // T07 域，本卡 NULL
        XCTAssertNil(row["estimated_bytes"])              // T07 域，本卡 NULL
        XCTAssertEqual(row["fetched_at"] as Double?, 1_800_000_000)
    }

    func testUpsertAssetOverwritesSameIdentifier() throws {
        let database = try makeDatabase()
        database.upsert(asset: makeAsset(id: "A", favorite: false), fetchedAt: Date())
        database.upsert(asset: makeAsset(id: "A", favorite: true), fetchedAt: Date())

        XCTAssertEqual(database.assetCount(), 1)
        let row = try XCTUnwrap(database.row(forSQL: "SELECT favorite FROM assets WHERE local_identifier = 'A'"))
        XCTAssertEqual(row["favorite"], true)
    }

    // MARK: featureprints 表

    func testFeatureprintsRoundTripAndVersionMismatch() throws {
        let database = try makeDatabase()
        database.upsert(asset: makeAsset(id: "A"), fetchedAt: Date())

        let payload = Data([0x11, 0x22, 0x33, 0x44])
        database.upsertFeatureprint(assetId: "A", data: payload, featureVersion: 1, computedAt: Date())

        XCTAssertEqual(try XCTUnwrap(database.featureprint(assetId: "A", featureVersion: 1)), payload)
        // featureVersion 不符 → 视为不存在（调用方重算）。
        XCTAssertNil(database.featureprint(assetId: "A", featureVersion: 2))
    }

    func testPurgeFeatureprintsKeepsCurrentVersion() throws {
        let database = try makeDatabase()
        // featureprints.asset_id 有外键（GRDB 默认开启外键约束）：
        // 必须先落父资产行，否则插入被拒且被 try? 吞掉。
        for id in ["old-1", "cur-1", "cur-2", "newer-9"] {
            database.upsert(asset: makeAsset(id: id), fetchedAt: Date())
        }
        for (id, version) in [("old-1", 0), ("cur-1", 1), ("cur-2", 1), ("newer-9", 9)] {
            database.upsertFeatureprint(assetId: id, data: Data([1]), featureVersion: version, computedAt: Date())
        }
        XCTAssertEqual(database.featureprintCount(), 4, "前置断言：脏数据确实已入库")

        database.purgeFeatureprints(keepingFeatureVersion: ScanStateMachine.featureVersion)

        XCTAssertEqual(database.featureprintCount(), 2)   // 只剩 version==1 的两行
        XCTAssertEqual(database.featureprint(assetId: "cur-1", featureVersion: 1)?.count, 1)
        XCTAssertNil(database.featureprint(assetId: "old-1", featureVersion: 0))
    }

    // MARK: decisions 表（含 CHECK 约束）

    func testDecisionsRoundTrip() throws {
        let database = try makeDatabase()
        database.upsert(asset: makeAsset(id: "A"), fetchedAt: Date())

        database.setDecision(assetId: "A", verdict: .delete, reason: "similar_group", decidedAt: Date(timeIntervalSince1970: 1_800_000_001))
        let decision = try XCTUnwrap(database.decision(assetId: "A"))
        XCTAssertEqual(decision.verdict, .delete)
        XCTAssertEqual(decision.reason, "similar_group")
        XCTAssertEqual(decision.decidedAt.timeIntervalSince1970, 1_800_000_001, accuracy: 0.001)

        // 覆写裁决
        database.setDecision(assetId: "A", verdict: .keep, reason: "user_kept", decidedAt: Date())
        XCTAssertEqual(try XCTUnwrap(database.decision(assetId: "A")).verdict, .keep)
    }

    func testDecisionsRejectsVerdictOutsideCheckConstraint() throws {
        let database = try makeDatabase()
        database.upsert(asset: makeAsset(id: "A"), fetchedAt: Date())
        XCTAssertThrowsError(
            try database.executeRaw(
                sql: "INSERT INTO decisions (asset_id, verdict, reason, decided_at) VALUES ('A', 'burn', 'r', 1)",
                arguments: []
            )
        )
    }


    // MARK: 迁移：升级路径与幂等

    func testSchemaUpgradePathPreservesData() throws {
        // 模拟旧版本库：只应用第一步迁移（有表无索引），写入一行资产。
        let queue = try DatabaseQueue()
        var legacyMigrator = DatabaseMigrator()
        let firstStep = try XCTUnwrap(PhotoLibraryDatabase.migrationSteps.first)
        legacyMigrator.registerMigration(firstStep.name) { db in
            for sql in firstStep.statements { try db.execute(sql: sql) }
        }
        try legacyMigrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO assets (
                  local_identifier, favorite, is_edited, media_type,
                  pixel_width, pixel_height, fetched_at
                ) VALUES ('legacy', 1, 0, 'image', 100, 100, 1)
                """
            )
        }

        // 升级到当前全量 schema：已应用步骤自动跳过，新步骤补齐；旧数据必须幸存。
        try PhotoLibraryDatabase.makeMigrator().migrate(queue)

        let indexName = try XCTUnwrap(queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_assets_created'"
            )
        })
        XCTAssertEqual(indexName, "idx_assets_created")
        let survivor = try XCTUnwrap(queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE local_identifier = 'legacy'")
        })
        XCTAssertEqual(survivor["media_type"], "image")
    }

    func testMigrationIsIdempotentAcrossRuns() throws {
        // 同一磁盘库打开两次：第二次迁移全部跳过、数据幸存（绝不 drop 重建）。
        // 这也是 T03 验收"中途杀进程"在存储层的模拟。
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("t03-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try PhotoLibraryDatabase(path: path)
        first.upsert(asset: makeAsset(id: "persist-1"), fetchedAt: Date())
        first.setKeyValue("42", forKey: "scan.progress")

        let second = try PhotoLibraryDatabase(path: path)
        XCTAssertEqual(second.assetCount(), 1)
        XCTAssertEqual(second.keyValue(forKey: "scan.progress"), "42")
    }

    // MARK: GRDBKeyValueStore（scan_state 表后端）

    func testKeyValueStoreReadWriteOverwriteDelete() throws {
        let store = GRDBKeyValueStore(database: try makeDatabase())

        XCTAssertNil(store.string(forKey: "k"))                       // 缺键 → nil
        store.setString("v1", forKey: "k")                            // 写
        XCTAssertEqual(store.string(forKey: "k"), "v1")
        store.setString("v2", forKey: "k")                            // 覆写
        XCTAssertEqual(store.string(forKey: "k"), "v2")
        store.setString(nil, forKey: "k")                             // 约定：nil 等价删除
        XCTAssertNil(store.string(forKey: "k"))
    }
}
