// MARK: - PhotoLibraryDatabase
// 职责：GRDB 持久化层。核心表的建库迁移（DDL 以 docs/tech-spec.md §4 为唯一权威）、
//       资产快照 upsert、特征读写、裁决与截图分类的落表入口。
// 任务卡：T03。
//
// 铁律：本地库只存分析结果与 PhotoKit identifier，任何情况下不复制原图字节；
//       迁移带版本号向前兼容（GRDB DatabaseMigrator）；仅 v3 为主键变更做受控表迁移。

import Foundation
import GRDB

struct FeatureprintWrite {
    let assetId: String
    let data: Data
    let featureVersion: Int
    let computedAt: Date
    let assetVersion: Date?
    let visionRequestVersion: Int

    init(
        assetId: String,
        data: Data,
        featureVersion: Int,
        computedAt: Date,
        assetVersion: Date? = nil,
        visionRequestVersion: Int = AppConfig.visionRequestVersion
    ) {
        self.assetId = assetId
        self.data = data
        self.featureVersion = featureVersion
        self.computedAt = computedAt
        self.assetVersion = assetVersion
        self.visionRequestVersion = visionRequestVersion
    }
}

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
        // v2（T15）：截图分类补 OCR 全文列——copy_text 动作与 LLM 兜底的数据源。
        // 只加列不重建（铁律：向前兼容迁移）。
        (name: "v2.screenshotOcrText", statements: [
            "ALTER TABLE screenshot_classifications ADD COLUMN ocr_text TEXT NOT NULL DEFAULT ''",
        ]),
        // v3：featureprints 原先以 asset_id 为主键，哈希、embedding、评分会互相覆盖。
        // 重建为 (asset_id, feature_kind) 复合主键，保留旧行并按信封首字节推断类型。
        (name: "v3.featureprintKinds", statements: [
            """
            CREATE TABLE featureprints_v3 (
              asset_id        TEXT NOT NULL REFERENCES assets(local_identifier) ON DELETE CASCADE,
              feature_kind    TEXT NOT NULL CHECK (feature_kind IN ('hash','embedding','scores','legacy')),
              feature_version INTEGER NOT NULL,
              data            BLOB    NOT NULL,
              computed_at     REAL NOT NULL,
              PRIMARY KEY (asset_id, feature_kind)
            )
            """,
            """
            INSERT INTO featureprints_v3 (asset_id, feature_kind, feature_version, data, computed_at)
            SELECT asset_id,
                   CASE hex(substr(data, 1, 1))
                     WHEN '01' THEN 'hash'
                     WHEN '02' THEN 'embedding'
                     WHEN '03' THEN 'scores'
                     ELSE 'legacy'
                   END,
                   feature_version, data, computed_at
            FROM featureprints
            """,
            "DROP TABLE featureprints",
            "ALTER TABLE featureprints_v3 RENAME TO featureprints",
            "CREATE INDEX IF NOT EXISTS idx_featureprints_version_kind ON featureprints(feature_version, feature_kind)",
        ]),
        // v4：删除审计状态与动作事件独立落表。动作不能覆盖删除/保留裁决，
        // 且同一资产可重复执行多个动作。
        (name: "v4.deletionAndActionAudit", statements: [
            "ALTER TABLE decisions ADD COLUMN deleted_at REAL",
            """
            CREATE TABLE IF NOT EXISTS action_events (
              id          INTEGER PRIMARY KEY AUTOINCREMENT,
              asset_id    TEXT NOT NULL REFERENCES assets(local_identifier) ON DELETE CASCADE,
              action      TEXT NOT NULL,
              happened_at REAL NOT NULL
            )
            """,
            // 兼容 v1/v2 曾把动作写进 decisions.reason 的数据，迁移为独立事件；
            // 原裁决行保留，避免丢失用户当时的处理状态。
            """
            INSERT INTO action_events (asset_id, action, happened_at)
            SELECT asset_id, substr(reason, 8), decided_at
            FROM decisions
            WHERE reason LIKE 'action:%' AND length(trim(substr(reason, 8))) > 0
            """,
            "CREATE INDEX IF NOT EXISTS idx_decisions_verdict_deleted ON decisions(verdict, deleted_at)",
            "CREATE INDEX IF NOT EXISTS idx_action_events_happened ON action_events(happened_at)",
        ]),
        // v5：把 PhotoKit 修改版本与特征算法/请求版本一起绑定。
        // 旧行的 asset_version 保持 NULL，读取端在生产扫描中视为不可复用；
        // 这样迁移不会把无法证明新鲜度的历史特征重新放进建议链路。
        (name: "v5.featureFreshness", statements: [
            "ALTER TABLE assets ADD COLUMN modification_date REAL",
            "ALTER TABLE featureprints ADD COLUMN asset_version REAL",
            "ALTER TABLE featureprints ADD COLUMN vision_request_version INTEGER NOT NULL DEFAULT 1",
            "CREATE INDEX IF NOT EXISTS idx_featureprints_freshness ON featureprints(feature_version, vision_request_version, asset_version)",
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

    /// 结果快照的单事务提交入口。任何一个键写失败都会回滚整批，
    /// 让恢复逻辑只能看到完整旧快照或完整新快照。
    @discardableResult
    func setKeyValuesAtomically(_ values: [String: String?]) -> Bool {
        do {
            try writer.write { db in
                for (key, value) in values {
                    guard !key.isEmpty else { continue }
                    if let value {
                        try db.execute(
                            sql: """
                            INSERT INTO scan_state (key, value) VALUES (?, ?)
                            ON CONFLICT(key) DO UPDATE SET value = excluded.value
                            """,
                            arguments: [key, value]
                        )
                    } else {
                        try db.execute(
                            sql: "DELETE FROM scan_state WHERE key = ?",
                            arguments: [key]
                        )
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: assets 表

    /// upsert by local_identifier。estimated_bytes 由引擎在 fetching 阶段经
    /// MediaSizeEstimator 填充（T17）；burst_id 属后续域保持默认 NULL；
    /// locally_available 如实落表（iCloud 未下载=0，大媒体页折叠分组依据）。
    @discardableResult
    func upsert(
        asset record: AssetRecord,
        fetchedAt: Date,
        locallyAvailable: Bool? = nil,
        estimatedBytes: Int64? = nil
    ) -> Bool {
        guard !record.localIdentifier.isEmpty else { return false }
        let availability = locallyAvailable ?? record.locallyAvailable
        do {
            try writer.write { db in
                try Self.writeAsset(
                    db: db,
                    record: record,
                    fetchedAt: fetchedAt,
                    locallyAvailable: availability,
                    estimatedBytes: estimatedBytes
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// 批量写入资产快照；整个 fetching 轮次共用一个事务，避免 5 万张相册产生
    /// 5 万次独立提交。单资产 upsert 仍保留给 PhotoKit 增量事件和测试调用。
    @discardableResult
    func upsert(assets records: [AssetRecord], fetchedAt: Date) -> Bool {
        let inputs = records.compactMap { record -> (AssetRecord, Bool, Int64?)? in
            guard !record.localIdentifier.isEmpty else { return nil }
            return (record, record.locallyAvailable, MediaSizeEstimator.estimatedBytes(for: record))
        }
        guard !inputs.isEmpty else { return true }
        do {
            try writer.write { db in
                for (record, locallyAvailable, estimatedBytes) in inputs {
                    try Self.writeAsset(
                        db: db,
                        record: record,
                        fetchedAt: fetchedAt,
                        locallyAvailable: locallyAvailable,
                        estimatedBytes: estimatedBytes
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 用一次完整的 PhotoKit 快照校准本地索引：写入当前资产并移除相册中
    /// 已不存在的旧行。整个替换在同一事务内完成，进程中断时不会留下半套快照。
    /// 增量变更不能调用此方法（应使用 upsert + removeAssetsFromLibrary）。
    @discardableResult
    func replaceAssetSnapshot(_ records: [AssetRecord], fetchedAt: Date) -> Bool {
        let inputs = records.compactMap { record -> (AssetRecord, Bool, Int64?)? in
            guard !record.localIdentifier.isEmpty else { return nil }
            return (record, record.locallyAvailable, MediaSizeEstimator.estimatedBytes(for: record))
        }
        let incomingIDs = Set(inputs.map { $0.0.localIdentifier })
        do {
            try writer.write { db in
                for (record, locallyAvailable, estimatedBytes) in inputs {
                    try Self.writeAsset(
                        db: db,
                        record: record,
                        fetchedAt: fetchedAt,
                        locallyAvailable: locallyAvailable,
                        estimatedBytes: estimatedBytes
                    )
                }

                // 不使用 IN (...)，避免 5 万张相册触碰 SQLite 默认绑定参数上限。
                // 注意：空快照也必须继续执行删除循环；否则相册被清空后，
                // 本地索引会永久残留旧资产。
                let existingIDs = try String.fetchAll(db, sql: "SELECT local_identifier FROM assets")
                for staleID in existingIDs where !incomingIDs.contains(staleID) {
                    try db.execute(
                        sql: "DELETE FROM assets WHERE local_identifier = ?",
                        arguments: [staleID]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 删除指定资产的全部分析特征。相册元数据发生变化时旧特征不能复用，
    /// 否则同一 localIdentifier 会继续使用修改前的图像结果。
    func removeFeatureprints(assetIds: [String]) {
        guard !assetIds.isEmpty else { return }
        try? writer.write { db in
            for assetId in Set(assetIds) {
                try db.execute(
                    sql: "DELETE FROM featureprints WHERE asset_id = ?",
                    arguments: [assetId]
                )
            }
        }
    }

    /// 清空全部分析特征。新的全量扫描在没有资产内容版本可比时调用，
    /// 防止同一 localIdentifier 的修改内容复用旧 hash/embedding/score。
    func removeAllFeatureprints() {
        try? writer.write { db in
            try db.execute(sql: "DELETE FROM featureprints")
        }
    }

    /// 清除由算法生成、但尚未得到系统删除确认的旧建议。用户 keep、
    /// 已确认删除和其它用户裁决均保留。
    func clearAutomaticDeleteDecisions(assetIds: [String]? = nil) {
        // nil 表示清空全部；显式传入空数组表示没有资产变更，必须是 no-op，
        // 不能把一次“无 id 的变更通知”误解成全量清理。
        if let assetIds, assetIds.isEmpty { return }
        try? writer.write { db in
            let automaticReason = "(reason LIKE 'low_quality:%' OR reason = 'large_media')"
            if let assetIds, !assetIds.isEmpty {
                for assetId in Set(assetIds) {
                    try db.execute(
                        sql: """
                        DELETE FROM decisions
                        WHERE asset_id = ? AND verdict = 'delete' AND deleted_at IS NULL
                          AND \(automaticReason)
                        """,
                        arguments: [assetId]
                    )
                }
            } else {
                try db.execute(
                    sql: """
                    DELETE FROM decisions
                    WHERE verdict = 'delete' AND deleted_at IS NULL
                      AND \(automaticReason)
                    """
                )
            }
        }
    }

    func assetCount() -> Int {
        (try? writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets")
        }) ?? 0
    }

    // MARK: featureprints 表

    @discardableResult
    func upsertFeatureprint(
        assetId: String,
        data: Data,
        featureVersion: Int,
        computedAt: Date,
        assetVersion: Date? = nil,
        visionRequestVersion: Int = AppConfig.visionRequestVersion
    ) -> Bool {
        guard !assetId.isEmpty, !data.isEmpty else { return false }
        return upsertFeatureprints([
            FeatureprintWrite(
                assetId: assetId,
                data: data,
                featureVersion: featureVersion,
                computedAt: computedAt,
                assetVersion: assetVersion,
                visionRequestVersion: visionRequestVersion
            )
        ])
    }

    /// 特征按批次在同一事务写入，避免五万张相册产生五万次提交。
    @discardableResult
    func upsertFeatureprints(_ writes: [FeatureprintWrite]) -> Bool {
        let validWrites = writes.filter { !$0.assetId.isEmpty && !$0.data.isEmpty }
        guard !validWrites.isEmpty else { return true }
        do {
            try writer.write { db in
                for write in validWrites {
                    let kind = Self.featureKind(for: write.data)
                    try db.execute(
                        sql: """
                        INSERT INTO featureprints (
                          asset_id, feature_kind, feature_version, data, computed_at,
                          asset_version, vision_request_version
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(asset_id, feature_kind) DO UPDATE SET
                          feature_version = excluded.feature_version,
                          data = excluded.data,
                          computed_at = excluded.computed_at,
                          asset_version = excluded.asset_version,
                          vision_request_version = excluded.vision_request_version
                        """,
                        arguments: [
                            write.assetId, kind, write.featureVersion, write.data,
                            write.computedAt.timeIntervalSince1970,
                            write.assetVersion?.timeIntervalSince1970,
                            write.visionRequestVersion,
                        ]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 读回某资产的特征；同一资产可能同时有哈希、向量和评分，
    /// 这里保留兼容接口，调用方需要具体类型时使用下面三个批量读取方法。
    func featureprint(assetId: String, featureVersion: Int) -> Data? {
        try? writer.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT data FROM featureprints
                WHERE asset_id = ? AND feature_version = ?
                ORDER BY feature_kind
                LIMIT 1
                """,
                arguments: [assetId, featureVersion]
            )
        }
    }

    /// 读回指定版本的全部 pHash（hex 字符串）。供杀进程续扫时复用已算特征，
    /// 避免整段 hashing 阶段空转重算。
    func allFeatureprintHashes(
        featureVersion: Int,
        validAssetVersions: [String: Date?]? = nil
    ) -> [String: String] {
        var result: [String: String] = [:]
        try? writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id, data, asset_version, vision_request_version
                FROM featureprints
                WHERE feature_version = ? AND feature_kind = 'hash'
                """,
                arguments: [featureVersion]
            )
            for row in rows {
                if Self.isFeatureFresh(
                    row: row,
                    validAssetVersions: validAssetVersions
                ),
                let data = row["data"] as? Data,
                   let text = FeaturePrintCodec.decodeHash(data) {
                    result[row["asset_id"] as String] = text
                }
            }
        }
        return result
    }

    /// 读回指定版本的全部 embedding（已归一化向量）。供续扫与聚类阶段复用。
    func allFeatureprintEmbeddings(
        featureVersion: Int,
        validAssetVersions: [String: Date?]? = nil
    ) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        try? writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id, data, asset_version, vision_request_version
                FROM featureprints
                WHERE feature_version = ? AND feature_kind = 'embedding'
                """,
                arguments: [featureVersion]
            )
            for row in rows {
                if Self.isFeatureFresh(
                    row: row,
                    validAssetVersions: validAssetVersions
                ),
                let data = row["data"] as? Data,
                   let vector = FeaturePrintCodec.decodeEmbedding(data),
                   EmbeddingMath.isUsable(vector) {
                    result[row["asset_id"] as String] = EmbeddingMath.normalized(vector)
                }
            }
        }
        return result
    }

    /// 读回指定版本的全部四维特征分数。供 scoring 阶段续扫复用。
    func allFeatureprintScores(
        featureVersion: Int,
        validAssetVersions: [String: Date?]? = nil
    ) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        try? writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id, data, asset_version, vision_request_version
                FROM featureprints
                WHERE feature_version = ? AND feature_kind = 'scores'
                """,
                arguments: [featureVersion]
            )
            for row in rows {
                if Self.isFeatureFresh(
                    row: row,
                    validAssetVersions: validAssetVersions
                ),
                let data = row["data"] as? Data,
                   let scores = FeaturePrintCodec.decodeScores(data) {
                    result[row["asset_id"] as String] = scores
                }
            }
        }
        return result
    }

    /// 删除完成后批量落审计状态。deleted_at 使"待确认"和"已获系统批准"分开，
    /// 同时保留行供诊断；如果资产稍后从系统相册消失，外键级联仍可清理它。
    @discardableResult
    func markDeleted(assetIds: [String], at date: Date = Date()) -> Bool {
        guard !assetIds.isEmpty else { return true }
        do {
            try writer.write { db in
                for assetId in Set(assetIds) {
                    // PhotoKit 可能在确认框前已把某个 id 从库中移除；跳过不存在的
                    // 父行，避免一个过期 id 让整个批次因外键约束回滚。
                    guard (try Int.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM assets WHERE local_identifier = ?)",
                        arguments: [assetId]
                    ) ?? 0) == 1 else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO decisions (asset_id, verdict, reason, decided_at, deleted_at)
                        VALUES (?, 'delete', 'user_approved_system_confirm', ?, ?)
                        ON CONFLICT(asset_id) DO UPDATE SET
                          verdict = excluded.verdict,
                          reason = excluded.reason,
                          decided_at = excluded.decided_at,
                          deleted_at = excluded.deleted_at
                        """,
                        arguments: [assetId, date.timeIntervalSince1970, date.timeIntervalSince1970]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 相册外部删除后移除本地索引；外键级联清理特征、裁决和动作审计。
    /// 这与 markDeleted 分开，避免把用户在系统确认框外的删除伪装成已批准操作。
    func removeAssetsFromLibrary(assetIds: [String]) {
        guard !assetIds.isEmpty else { return }
        try? writer.write { db in
            for assetId in Set(assetIds) {
                try db.execute(
                    sql: "DELETE FROM assets WHERE local_identifier = ?",
                    arguments: [assetId]
                )
            }
        }
    }

    // MARK: Daily Inbox 计数（T14）

    /// 当日新增：拍摄时间位于 [windowStart, windowEnd) 的资产数。
    /// 未传结束时间时保留旧的"起点以后"兼容语义。
    func countAssets(createdAtOrAfter windowStart: Date, before windowEnd: Date? = nil) -> Int {
        (try? writer.read { db in
            if let windowEnd {
                return try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM assets a
                    WHERE a.creation_date >= ? AND a.creation_date < ?
                      AND NOT EXISTS (
                        SELECT 1 FROM decisions d
                        WHERE d.asset_id = a.local_identifier AND d.deleted_at IS NOT NULL
                      )
                    """,
                    arguments: [windowStart.timeIntervalSince1970, windowEnd.timeIntervalSince1970]
                )
            }
            return try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM assets a
                WHERE a.creation_date >= ?
                  AND NOT EXISTS (
                    SELECT 1 FROM decisions d
                    WHERE d.asset_id = a.local_identifier AND d.deleted_at IS NOT NULL
                  )
                """,
                arguments: [windowStart.timeIntervalSince1970]
            )
        }) ?? 0
    }

    /// 当日任务动作数：独立事件表支持同一资产重复执行动作。
    func countActions(atOrAfter windowStart: Date, before windowEnd: Date? = nil) -> Int {
        (try? writer.read { db in
            if let windowEnd {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM action_events WHERE happened_at >= ? AND happened_at < ?",
                    arguments: [windowStart.timeIntervalSince1970, windowEnd.timeIntervalSince1970]
                )
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM action_events WHERE happened_at >= ?",
                arguments: [windowStart.timeIntervalSince1970]
            )
        }) ?? 0
    }

    /// 当前有效删除裁决数（尚未获得系统确认的 delete）。
    func countDeleteVerdicts() -> Int {
        (try? writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM decisions WHERE verdict = 'delete' AND deleted_at IS NULL"
            )
        }) ?? 0
    }

    /// 用户已经产生足够历史反馈时，评分引擎可以退出冷启动权重。
    func decisionCount() -> Int {
        (try? writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decisions")
        }) ?? 0
    }

    /// 任务动作落库（T12 动作执行后调用，供 Daily Inbox 统计）。
    func markActionTaken(assetId: String, action: String, at date: Date = Date()) {
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetId.isEmpty, !normalizedAction.isEmpty else { return }
        try? writer.write { db in
            try db.execute(
                sql: "INSERT INTO action_events (asset_id, action, happened_at) VALUES (?, ?, ?)",
                arguments: [assetId, normalizedAction, date.timeIntervalSince1970]
            )
        }
    }

    /// 返回已有指定裁决的资产 id，用于自动候选生成时尊重用户的 keep。
    func assetIDs(withVerdict verdict: Verdict) -> Set<String> {
        (try? assetIDsResult(withVerdict: verdict).get()) ?? []
    }

    /// 安全相关读取不能把数据库异常伪装成空集合。自动建议生成使用这个
    /// 显式结果；失败时调用方必须暂停建议，而不是放行更多资产。
    func assetIDsResult(withVerdict verdict: Verdict) -> Result<Set<String>, Error> {
        do {
            let ids = try writer.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT asset_id FROM decisions WHERE verdict = ? AND deleted_at IS NULL",
                    arguments: [verdict.rawValue]
                )
            }
            return .success(Set(ids))
        } catch {
            return .failure(error)
        }
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

    @discardableResult
    func setDecision(assetId: String, verdict: Verdict, reason: String, decidedAt: Date) -> Bool {
        guard !assetId.isEmpty else { return false }
        do {
            try writer.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO decisions (asset_id, verdict, reason, decided_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(asset_id) DO UPDATE SET
                      verdict = excluded.verdict,
                      reason = excluded.reason,
                      decided_at = excluded.decided_at,
                      deleted_at = NULL
                    """,
                    arguments: [assetId, verdict.rawValue, reason, decidedAt.timeIntervalSince1970]
                )
            }
            return true
        } catch {
            return false
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

    // MARK: 辅助

    private static func writeAsset(
        db: Database,
        record: AssetRecord,
        fetchedAt: Date,
        locallyAvailable: Bool,
        estimatedBytes: Int64?
    ) throws {
        let width = max(0, record.pixelWidth)
        let height = max(0, record.pixelHeight)
        let duration: Double?
        if record.mediaType == .video, record.duration.isFinite, record.duration >= 0 {
            duration = record.duration
        } else {
            duration = nil
        }
        let creationTimestamp = record.creationDate?.timeIntervalSince1970
        let safeCreationTimestamp = creationTimestamp.flatMap { $0.isFinite ? $0 : nil }
        let safeEstimatedBytes = estimatedBytes.flatMap { $0 >= 0 ? $0 : nil }
        let safeFetchedTimestamp = fetchedAt.timeIntervalSince1970.isFinite
            ? fetchedAt.timeIntervalSince1970
            : 0

        try db.execute(
            sql: """
            INSERT INTO assets (
              local_identifier, favorite, is_edited, media_type,
              pixel_width, pixel_height, duration_seconds, creation_date,
              modification_date, is_screenshot, burst_id, estimated_bytes,
              locally_available, fetched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_identifier) DO UPDATE SET
              favorite = excluded.favorite,
              is_edited = excluded.is_edited,
              media_type = excluded.media_type,
              pixel_width = excluded.pixel_width,
              pixel_height = excluded.pixel_height,
              duration_seconds = excluded.duration_seconds,
              creation_date = excluded.creation_date,
              modification_date = excluded.modification_date,
              is_screenshot = excluded.is_screenshot,
              estimated_bytes = excluded.estimated_bytes,
              locally_available = excluded.locally_available,
              fetched_at = excluded.fetched_at
            """,
            arguments: [
                record.localIdentifier,
                record.favorite,
                record.isEdited,
                Self.storageName(of: record.mediaType),
                width,
                height,
                duration,
                safeCreationTimestamp,
                record.modificationDate?.timeIntervalSince1970,
                record.isScreenshot,
                nil as String?,
                safeEstimatedBytes,
                locallyAvailable,
                safeFetchedTimestamp,
            ]
        )
    }

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

    /// 由 FeaturePrintCodec 的首字节确定物理分区；未知旧数据保留为 legacy，
    /// 不会和三类新特征互相覆盖。
    private static func featureKind(for data: Data) -> String {
        switch data.first {
        case 1: return "hash"
        case 2: return "embedding"
        case 3: return "scores"
        default: return "legacy"
        }
    }

    /// 读取特征时同时校验请求版本与当前资产修改版本。
    /// `validAssetVersions == nil` 保留旧测试/诊断 API 的读取语义；生产扫描
    /// 总是传入完整映射，未知或 nil 版本一律视为不可复用。
    private static func isFeatureFresh(
        row: Row,
        validAssetVersions: [String: Date?]?
    ) -> Bool {
        guard (row["vision_request_version"] as Int? ?? 0)
                == AppConfig.visionRequestVersion else { return false }
        guard let validAssetVersions else { return true }
        let assetID = row["asset_id"] as String
        guard let expectedOptional = validAssetVersions[assetID],
              let expected = expectedOptional,
              let stored = row["asset_version"] as Double? else {
            return false
        }
        return abs(stored - expected.timeIntervalSince1970) < 0.000_001
    }
}
