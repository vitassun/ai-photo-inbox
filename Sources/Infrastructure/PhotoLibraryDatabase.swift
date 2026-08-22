// MARK: - PhotoLibraryDatabase
// 职责：GRDB 持久化层。五张表的建库迁移（DDL 以 docs/tech-spec.md §4 为唯一权威）、
//       资产快照 upsert、特征读写、裁决与截图分类的落表入口。
// 任务卡：T03。
//
// 铁律：本地库只存分析结果与 PhotoKit identifier，任何情况下不复制原图字节；
//       迁移带版本号向前兼容（GRDB DatabaseMigrator），绝不 drop 重建。

import Foundation
import GRDB

final class PhotoLibraryDatabase {

    /// 迁移步骤（有序）。拆成"建表/建索引"两步既贴合 DDL，
    /// 也让测试能组合前缀模拟旧版本库的升级路径。
    static let migrationSteps: [(name: String, statements: [String])] = [
        (name: "v1.createTables", statements: [
            """
            CREATE TABLE IF NOT EXISTS assets (
              local_identifier TEXT PRIMARY KEY,
              favorite         INTEGER NOT NULL DEFAULT 0,
              is_edited        INTEGER NOT NULL DEFAULT 0,
              media_type       TEXT    NOT NULL,
              pixel_width      INTEGER NOT NULL,
              pixel_height     INTEGER NOT NULL,
              duration_seconds REAL,
              creation_date    REAL,
              is_screenshot    INTEGER NOT NULL DEFAULT 0,
              burst_id         TEXT,
              estimated_bytes  INTEGER,
              locally_available INTEGER NOT NULL DEFAULT 1,
              fetched_at       REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS featureprints (
              asset_id        TEXT PRIMARY KEY REFERENCES assets(local_identifier) ON DELETE CASCADE,
              feature_version INTEGER NOT NULL,
              data            BLOB    NOT NULL,
              computed_at     REAL NOT NULL
            )
            """,
            "CREATE TABLE IF NOT EXISTS scan_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS decisions (
              asset_id    TEXT PRIMARY KEY REFERENCES assets(local_identifier) ON DELETE CASCADE,
              verdict     TEXT NOT NULL CHECK (verdict IN ('keep','delete','archive','todo')),
              reason      TEXT NOT NULL,
              decided_at  REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS screenshot_classifications (
              asset_id       TEXT PRIMARY KEY REFERENCES assets(local_identifier) ON DELETE CASCADE,
              category       TEXT NOT NULL CHECK (category IN
                               ('courier','verification_code','boarding_pass','product',
                                'address','receipt','qr_code','chat','other')),
              confidence     REAL NOT NULL,
              extracted_fields TEXT NOT NULL DEFAULT '{}',
              suggested_action TEXT NOT NULL,
              temporary_likelihood REAL NOT NULL,
              source         TEXT NOT NULL DEFAULT 'rule',
              classified_at  REAL NOT NULL
            )
            """,
        ]),
        (name: "v1.indexes", statements: [
            "CREATE INDEX IF NOT EXISTS idx_assets_created ON assets(creation_date)",
        ]),
    ]

    static func makeMigrator(steps: [(name: String, statements: [String])] = migrationSteps) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for step in steps {
            migrator.registerMigration(step.name) { db in
                for sql in step.statements {
                    try db.execute(sql: sql)
                }
            }
        }
        return migrator
    }

    private let writer: any DatabaseWriter

    // MARK: 生命周期

    /// 生产路径：磁盘库（进程被杀后断点续扫依赖它）。
    init(path: String) throws {
        writer = try DatabasePool(path: path)
        try Self.makeMigrator().migrate(writer)
    }

    /// 测试/Preview 路径：匿名内存库。
    static func inMemory() throws -> PhotoLibraryDatabase {
        let database = PhotoLibraryDatabase(writer: try DatabaseQueue())
        try Self.makeMigrator().migrate(database.writer)
        return database
    }

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: KeyValueStore 后端（scan_state 表）

    func keyValue(forKey key: String) -> String? {
        try? writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM scan_state WHERE key = ?",
                arguments: [key]
            )
        }
    }

    func setKeyValue(_ value: String?, forKey key: String) {
        try? writer.write { db in
            if let value {
                try db.execute(
                    sql: """
                    INSERT INTO scan_state (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM scan_state WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: assets 表

    /// upsert by local_identifier。estimated_bytes/burst_id/locally_available
    /// 属 T07 域，本卡保持默认值（NULL / nil / 1）。
    func upsert(asset record: AssetRecord, fetchedAt: Date, locallyAvailable: Bool = true) {
        try? writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO assets (
                  local_identifier, favorite, is_edited, media_type,
                  pixel_width, pixel_height, duration_seconds, creation_date,
                  is_screenshot, burst_id, estimated_bytes, locally_available, fetched_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(local_identifier) DO UPDATE SET
                  favorite = excluded.favorite,
                  is_edited = excluded.is_edited,
                  media_type = excluded.media_type,
                  pixel_width = excluded.pixel_width,
                  pixel_height = excluded.pixel_height,
                  duration_seconds = excluded.duration_seconds,
                  creation_date = excluded.creation_date,
                  is_screenshot = excluded.is_screenshot,
                  locally_available = excluded.locally_available,
                  fetched_at = excluded.fetched_at
                """,
                arguments: [
                    record.localIdentifier,
                    record.favorite,
                    record.isEdited,
                    Self.storageName(of: record.mediaType),
                    record.pixelWidth,
                    record.pixelHeight,
                    record.mediaType == .video ? record.duration : nil,
                    record.creationDate?.timeIntervalSince1970,
                    record.isScreenshot,
                    nil as String?,
                    nil as Int?,
                    locallyAvailable,
                    fetchedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    func assetCount() -> Int {
        (try? writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets")
        }) ?? 0
    }

    // MARK: featureprints 表

    func upsertFeatureprint(assetId: String, data: Data, featureVersion: Int, computedAt: Date) {
        try? writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO featureprints (asset_id, feature_version, data, computed_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                  feature_version = excluded.feature_version,
                  data = excluded.data,
                  computed_at = excluded.computed_at
                """,
                arguments: [assetId, featureVersion, data, computedAt.timeIntervalSince1970]
            )
        }
    }

    /// 读回特征；featureVersion 不匹配时返回 nil（调用方视为需重算）。
    func featureprint(assetId: String, featureVersion: Int) -> Data? {
        try? writer.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT data FROM featureprints WHERE asset_id = ? AND feature_version = ?",
                arguments: [assetId, featureVersion]
            )
        }
    }

    /// 读回指定版本的全部 pHash（hex 字符串）。供杀进程续扫时复用已算特征，
    /// 避免整段 hashing 阶段空转重算。
    func allFeatureprintHashes(featureVersion: Int) -> [String: String] {
        var result: [String: String] = [:]
        try? writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT asset_id, data FROM featureprints WHERE feature_version = ?",
                arguments: [featureVersion]
            )
            for row in rows {
                if let data = row["data"] as? Data,
                   let text = FeaturePrintCodec.decodeHash(data) {
                    result[row["asset_id"] as String] = text
                }
            }
        }
        return result
    }

    /// 读回指定版本的全部 embedding（已归一化向量）。供续扫与聚类阶段复用。
    func allFeatureprintEmbeddings(featureVersion: Int) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        try? writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT asset_id, data FROM featureprints WHERE feature_version = ?",
                arguments: [featureVersion]
            )
            for row in rows {
                if let data = row["data"] as? Data,
                   let vector = FeaturePrintCodec.decodeEmbedding(data) {
                    result[row["asset_id"] as String] = vector
                }
            }
        }
        return result
    }

    /// 读回指定版本的全部四维特征分数。供 scoring 阶段续扫复用。
    func allFeatureprintScores(featureVersion: Int) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        try? writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT asset_id, data FROM featureprints WHERE feature_version = ?",
                arguments: [featureVersion]
            )
            for row in rows {
                if let data = row["data"] as? Data,
                   let scores = FeaturePrintCodec.decodeScores(data) {
                    result[row["asset_id"] as String] = scores
                }
            }
        }
        return result
    }

    /// 丢弃非当前版本的特征行（ScanStateMachine.FEATURE_VERSION 变更后的脏数据清理）。
    func purgeFeatureprints(keepingFeatureVersion version: Int) {
        try? writer.write { db in
            try db.execute(
                sql: "DELETE FROM featureprints WHERE feature_version != ?",
                arguments: [version]
            )
        }
    }

    func featureprintCount() -> Int {
        (try? writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM featureprints")
        }) ?? 0
    }

    // MARK: decisions 表

    func setDecision(assetId: String, verdict: Verdict, reason: String, decidedAt: Date) {
        try? writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO decisions (asset_id, verdict, reason, decided_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                  verdict = excluded.verdict,
                  reason = excluded.reason,
                  decided_at = excluded.decided_at
                """,
                arguments: [assetId, verdict.rawValue, reason, decidedAt.timeIntervalSince1970]
            )
        }
    }

    func decision(assetId: String) -> (verdict: Verdict, reason: String, decidedAt: Date)? {
        try? writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT verdict, reason, decided_at FROM decisions WHERE asset_id = ?",
                arguments: [assetId]
            ).map { row in
                (
                    Verdict(rawValue: row["verdict"]) ?? .todo,
                    row["reason"] as String,
                    Date(timeIntervalSince1970: row["decided_at"])
                )
            }
        }
    }

    // MARK: screenshot_classifications 表

    struct ScreenshotClassification {
        var assetId: String
        var category: String          // DDL CHECK 词表内
        var confidence: Double
        var extractedFieldsJSON: String
        var suggestedAction: String
        var temporaryLikelihood: Double
        var source: String            // rule | llm | vision_utility
        var classifiedAt: Date
    }

    func upsertScreenshotClassification(_ classification: ScreenshotClassification) {
        try? writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO screenshot_classifications (
                  asset_id, category, confidence, extracted_fields,
                  suggested_action, temporary_likelihood, source, classified_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                  category = excluded.category,
                  confidence = excluded.confidence,
                  extracted_fields = excluded.extracted_fields,
                  suggested_action = excluded.suggested_action,
                  temporary_likelihood = excluded.temporary_likelihood,
                  source = excluded.source,
                  classified_at = excluded.classified_at
                """,
                arguments: [
                    classification.assetId,
                    classification.category,
                    classification.confidence,
                    classification.extractedFieldsJSON,
                    classification.suggestedAction,
                    classification.temporaryLikelihood,
                    classification.source,
                    classification.classifiedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    func screenshotClassification(assetId: String) -> ScreenshotClassification? {
        try? writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT asset_id, category, confidence, extracted_fields,
                       suggested_action, temporary_likelihood, source, classified_at
                FROM screenshot_classifications WHERE asset_id = ?
                """,
                arguments: [assetId]
            ).map { row in
                ScreenshotClassification(
                    assetId: row["asset_id"],
                    category: row["category"],
                    confidence: row["confidence"],
                    extractedFieldsJSON: row["extracted_fields"],
                    suggestedAction: row["suggested_action"],
                    temporaryLikelihood: row["temporary_likelihood"],
                    source: row["source"],
                    classifiedAt: Date(timeIntervalSince1970: row["classified_at"])
                )
            }
        }
    }

    // MARK: 辅助

    /// 原始单行读取（内部可见，供测试逐字段断言与诊断）。
    func row(forSQL sql: String, arguments: [Any] = []) -> Row? {
        try? writer.read { db in
            // 调用方契约：只传可绑定类型（String/Int/Double/Bool/Data/nil），
            // StatementArguments 的 failable init 因此不会失败。
            try Row.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)!)
        }
    }

    /// 抛错的原始写入口（内部可见，供测试验证 DDL CHECK/外键约束真实存在）。
    func executeRaw(sql: String, arguments: [Any] = []) throws {
        try writer.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(arguments)!)
        }
    }

    /// AssetMediaType → DDL media_type 词表。livePhoto 由 T07 LivePhoto 配对引入，本卡不产出。
    private static func storageName(of type: AssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .unknown: return "unknown"
        }
    }
}
