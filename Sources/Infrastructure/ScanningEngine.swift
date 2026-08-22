// MARK: - ScanningEngine
// 职责：ScanStateMachine 的真实流水线驱动器（适配层，不改状态机公开语义）。
//       fetching 阶段经 PhotoLibraryServiceProtocol 拉元数据并 upsert 进 assets 表；
//       hashing/embedding/clustering/scoring 由后续卡接入真实计算，当前占位推进。
//       断点续扫：phase/progress 由状态机持久化；进程被杀后新实例从库恢复。
// 任务卡：T03。
//
// 并发模型：
//   - 状态机非线程安全 → 全部读写收敛在 workQueue（串行）上；
//   - pause() 从任意线程调用，只原子置一个请求标志，由驱动循环在
//     资产/阶段边界消费该标志并在队列上调 machine.pause —— 绝不把
//     标志设置本身排进工作队列（会排在长任务后面永远轮不到）。

import Foundation

final class ScanningEngine: ScanningEngineProtocol {

    private let machine: ScanStateMachine
    private let photoLibrary: PhotoLibraryServiceProtocol
    private let database: PhotoLibraryDatabase

    /// 状态机的全部读写都收敛到这条串行队列。
    private let workQueue: DispatchQueue
    /// 快照锁：保护镜像字段与暂停请求标志；绝不在持锁时触碰工作队列。
    private let snapshotLock = NSLock()
    private var phaseSnapshot: ScanPhase = .idle
    private var progressSnapshot: Double = 0
    private var pauseRequested = false

    private var progressHandler: ((ScanPhase, Double) -> Void)?

    /// 注入点：hashing 阶段的图像来源与哈希实现。
    /// 生产构造处传 PhotoKitImageDataProvider + PerceptualHash；
    /// 默认 nil 使 hashing 阶段空转推进（CI 单测注入假实现覆盖真实路径）。
    private let imageDataLoader: (String) -> Data?
    private let hashComputer: (Data) -> String?
    private let embeddingComputer: (Data) -> [Double]?
    /// scoring 阶段的四维特征来源（T08 analyze 的注入点）。
    private let featureAnalyzer: (Data) -> VisionAnalysisResult?
    /// 冷启动开关（V1 无反馈历史恒 false → favoriteBoost 翻倍；反馈历史属 T14 后）。
    private let hasUserData: Bool

    /// fetching 阶段捕获的当轮快照与哈希/向量结果（仅 workQueue 上读写）。
    private var fetchedRecords: [AssetRecord] = []
    private var hashByID: [String: String] = [:]
    private var embeddingByID: [String: [Double]] = [:]
    private var scoresByID: [String: VisionAnalysisResult] = [:]

    /// 候选组产出（T05 精比 / T09 评分消费）。镜像受 snapshotLock 保护。
    private var candidateGroupsSnapshot: [CandidateGroup] = []
    /// 评分后的组视图（Best Shot / 预删除候选集）。镜像受 snapshotLock 保护。
    private var scoredGroupsSnapshot: [ScoredGroup] = []

    /// 仅在 workQueue 上读写。
    private var isDriving = false

    init(
        photoLibrary: PhotoLibraryServiceProtocol,
        database: PhotoLibraryDatabase,
        store: KeyValueStore,
        imageDataLoader: @escaping (String) -> Data? = { _ in nil },
        hashComputer: @escaping (Data) -> String? = { _ in nil },
        embeddingComputer: @escaping (Data) -> [Double]? = { _ in nil },
        featureAnalyzer: @escaping (Data) -> VisionAnalysisResult? = { _ in nil },
        hasUserData: Bool = false,
        workQueue: DispatchQueue = DispatchQueue(label: "com.aiphotoinbox.ScanningEngine", qos: .userInitiated)
    ) {
        self.photoLibrary = photoLibrary
        self.database = database
        self.workQueue = workQueue
        self.imageDataLoader = imageDataLoader
        self.hashComputer = hashComputer
        self.embeddingComputer = embeddingComputer
        self.featureAnalyzer = featureAnalyzer
        self.hasUserData = hasUserData
        self.machine = ScanStateMachine(store: store)
        publishSnapshot()
    }

    var state: ScanPhase {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return phaseSnapshot
    }

    var currentProgress: Double {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return progressSnapshot
    }

    /// 删除完成后刷新内存视图（T10）：从候选组与评分视图里移除已删 id，
    /// 成员数跌破 2 的组随之解散。须在 workQueue 上调用（经 enqueue 包装）。
    func purgeDeletedFromViews(assetIds: [String], completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let deleted = Set(assetIds)

            var keptGroups: [CandidateGroup] = []
            for group in self.candidateGroupsSnapshot {
                let remaining = group.members.filter { !deleted.contains($0.localIdentifier) }
                if remaining.count >= 2 { keptGroups.append(group) }
            }
            self.candidateGroupsSnapshot = keptGroups

            var keptScored: [ScoredGroup] = []
            for scored in self.scoredGroupsSnapshot {
                let remaining = scored.members.filter { !deleted.contains($0.record.localIdentifier) }
                guard remaining.count >= 2 else { continue }
                let bestShotID = scored.bestShot?.record.localIdentifier
                let rebuiltMembers = remaining.map { member -> ScoredMember in
                    ScoredMember(
                        record: member.record,
                        score: member.score,
                        isBestShot: member.record.localIdentifier == bestShotID
                    )
                }
                let remainingIDs = Set(remaining.map(\.record.localIdentifier))
                keptScored.append(ScoredGroup(
                    groupID: scored.groupID,
                    reason: scored.reason,
                    members: rebuiltMembers,
                    preselectableIDs: scored.preselectableIDs.filter { remainingIDs.contains($0) && !deleted.contains($0) }
                ))
            }
            self.scoredGroupsSnapshot = keptScored
            completion?()
        }
    }

    /// 候选组快照（hashing/clustering 阶段产出）。
    var candidateGroups: [CandidateGroup] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return candidateGroupsSnapshot
    }

    /// 评分后的组视图（scoring 阶段产出：Best Shot / 预删除候选）。
    var scoredGroups: [ScoredGroup] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return scoredGroupsSnapshot
    }

    // MARK: ScanningEngineProtocol

    func runFullScan(progress: @escaping (ScanPhase, Double) -> Void) {
        snapshotLock.lock()
        progressHandler = progress
        pauseRequested = false
        snapshotLock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            // 从 idle 全量重扫：清掉旧版本特征脏数据（版本不符被状态机重置后的残留）。
            if self.machine.phase == .idle {
                self.database.purgeFeatureprints(keepingFeatureVersion: ScanStateMachine.featureVersion)
            }
            self.startDrivingOnQueue()
        }
    }

    func pause() {
        snapshotLock.lock()
        pauseRequested = true
        snapshotLock.unlock()
    }

    func resume() {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.machine.resume() else { return }
            self.publishSnapshot()
            self.reportProgress()
            self.snapshotLock.lock()
            self.pauseRequested = false
            self.snapshotLock.unlock()
            self.startDrivingOnQueue()
        }
    }

    // MARK: 驱动循环（以下方法只允许在 workQueue 上执行）

    private func startDrivingOnQueue() {
        // idle 引导：全新/重置后的扫描从这里迈出第一步。
        if machine.phase == .idle {
            machine.advance()
            publishSnapshot()
        }
        // 杀进程续跑：hashing/embedding/clustering 阶段的内存快照随进程消失，
        // 重拉元数据重建（元数据拉取廉价；已算特征从 featureprints 表复用，
        // 见 runHashingStage / runEmbeddingStage）。
        if machine.phase == .hashing || machine.phase == .embedding
            || machine.phase == .clustering || machine.phase == .scoring,
           fetchedRecords.isEmpty {
            fetchedRecords = photoLibrary.fetchAllAssets()
        }
        guard !isDriving, machine.isActive else { return }
        isDriving = true
        driveUntilInactive()
        isDriving = false
    }

    /// 逐阶段推进直到没有活动阶段。
    private func driveUntilInactive() {
        driveLoop: while machine.isActive {
            // 阶段边界响应暂停请求。
            if consumePauseRequest() {
                pauseOnQueue()
                break
            }

            switch machine.phase {
            case .fetching:
                if !runFetchingStage() {
                    // fetching 中途被打断：状态机已被置为 paused，本阶段不得推进
                    //（否则残缺的资产快照会被当成全量带进后续阶段）。
                    publishSnapshot()
                    reportProgress()
                    break driveLoop
                }
            case .hashing:
                if !runHashingStage() {
                    publishSnapshot()
                    reportProgress()
                    break driveLoop
                }
            case .embedding:
                if !runEmbeddingStage() {
                    publishSnapshot()
                    reportProgress()
                    break driveLoop
                }
            case .clustering:
                if !runClusteringStage() {
                    publishSnapshot()
                    reportProgress()
                    break driveLoop
                }
            case .scoring:
                if !runScoringStage() {
                    publishSnapshot()
                    reportProgress()
                    break driveLoop
                }
            case .idle, .done, .paused:
                break driveLoop
            }
        }
    }

    private func pauseOnQueue() {
        machine.pause(reason: "用户暂停")
        publishSnapshot()
        reportProgress()
    }

    /// fetching：拉全库元数据 → upsert assets 表 → 逐资产汇报进度。
    /// 返回 false 表示中途响应了暂停请求（已 pause、阶段未推进）。
    private func runFetchingStage() -> Bool {
        let assets = photoLibrary.fetchAllAssets()
        fetchedRecords = assets
        hashByID = [:]
        embeddingByID = [:]
        scoresByID = [:]
        let fetchedAt = Date()
        let total = max(assets.count, 1)
        for (index, record) in assets.enumerated() {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }
            database.upsert(asset: record, fetchedAt: fetchedAt)
            machine.setProgress(Double(index + 1) / Double(total))
            if (index + 1) % 200 == 0 || index + 1 == assets.count {
                publishSnapshot()
                reportProgress()
            }
        }
        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// hashing：逐资产拉缩略图 → 计算 pHash → 落 featureprints 表；
    /// 阶段末用 (时间×地理×pHash) 产出候选组。无注入实现时空转推进（占位语义保留）。
    /// 已持久化的当前版本哈希直接复用（杀进程续扫不重算）。
    private func runHashingStage() -> Bool {
        for (assetId, hash) in database.allFeatureprintHashes(featureVersion: ScanStateMachine.featureVersion) {
            hashByID[assetId] = hash
        }

        let total = max(fetchedRecords.count, 1)
        for (index, record) in fetchedRecords.enumerated() {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }
            if hashByID[record.localIdentifier] == nil,
               let data = imageDataLoader(record.localIdentifier),
               let hash = hashComputer(data) {
                hashByID[record.localIdentifier] = hash
                database.upsertFeatureprint(
                    assetId: record.localIdentifier,
                    data: FeaturePrintCodec.encodeHash(hash),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date()
                )
            }
            machine.setProgress(Double(index + 1) / Double(total))
            if (index + 1) % 200 == 0 || index + 1 == fetchedRecords.count {
                publishSnapshot()
                reportProgress()
            }
        }

        let groups = CandidateGrouper.groups(from: fetchedRecords, hashByID: hashByID)
        snapshotLock.lock()
        candidateGroupsSnapshot = groups
        snapshotLock.unlock()

        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// embedding：对未被 pHash 组认领的资产计算特征向量（L2 归一化）→ 落表。
    /// 已持久化的当前版本向量直接复用。无注入实现时空转推进。
    private func runEmbeddingStage() -> Bool {
        for (assetId, vector) in database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion) {
            embeddingByID[assetId] = vector
        }

        let claimed = Set(candidateGroupsSnapshot.flatMap(\.memberIDs))
        let pending = fetchedRecords.filter { !claimed.contains($0.localIdentifier) }
        let total = max(pending.count, 1)

        for (index, record) in pending.enumerated() {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }
            if embeddingByID[record.localIdentifier] == nil,
               let data = imageDataLoader(record.localIdentifier),
               let rawVector = embeddingComputer(data) {
                let vector = EmbeddingMath.normalized(rawVector)
                embeddingByID[record.localIdentifier] = vector
                database.upsertFeatureprint(
                    assetId: record.localIdentifier,
                    data: FeaturePrintCodec.encodeEmbedding(vector),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date()
                )
            }
            machine.setProgress(Double(index + 1) / Double(total))
            if (index + 1) % 200 == 0 || index + 1 == pending.count {
                publishSnapshot()
                reportProgress()
            }
        }

        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// clustering：在 (时间桶 × 地理单元) 内对 embedding 做阈值连通分量，
    /// ≥2 成员的分量并入候选组（pHash 已认领的资产不重复进组）。确定性输出。
    private func runClusteringStage() -> Bool {
        var groups = candidateGroupsSnapshot

        for unit in CandidateGrouper.timeGeoUnits(from: fetchedRecords) {
            let claimed = Set(groups.flatMap(\.memberIDs))
            let members = unit.members.filter {
                !claimed.contains($0.localIdentifier) && embeddingByID[$0.localIdentifier] != nil
            }
            guard members.count >= 2 else { continue }

            let vectors = members.map { member in
                (id: member.localIdentifier, vector: embeddingByID[member.localIdentifier]!)
            }
            for component in EmbeddingClusterer.components(of: vectors) where component.count >= 2 {
                let ids = Set(component)
                let groupMembers = members.filter { ids.contains($0.localIdentifier) }
                groups.append(
                    CandidateGroup(
                        id: "cand-\(unit.bucketIndex)-emb-\(groupMembers[0].localIdentifier)",
                        members: groupMembers,
                        reason: "时间×地理×embedding"
                    )
                )
            }
        }

        snapshotLock.lock()
        candidateGroupsSnapshot = groups
        snapshotLock.unlock()

        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// scoring：逐组跑 GroupScoring（KeepScore 接线 + 冗余度 + SafetyRules 过滤）
    /// → Best Shot 标记 → 预删除候选集。缺特征的资产按中性值参与评分。
    private func runScoringStage() -> Bool {
        // 复用已持久化的分数（信封 kind=3）。
        for (assetId, values) in database.allFeatureprintScores(featureVersion: ScanStateMachine.featureVersion)
        where values.count == 4 {
            scoresByID[assetId] = VisionAnalysisResult(
                clarity: values[0], aesthetics: values[1],
                faceQuality: values[2], saliency: values[3]
            )
        }

        let total = max(candidateGroupsSnapshot.count, 1)
        var scored: [ScoredGroup] = []
        for (index, group) in candidateGroupsSnapshot.enumerated() {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }

            // 缺分数的成员补算（经注入的分析器；失败回退中性值由聚合层保证）。
            for member in group.members where scoresByID[member.localIdentifier] == nil {
                guard let data = imageDataLoader(member.localIdentifier),
                      let features = featureAnalyzer(data) else { continue }
                scoresByID[member.localIdentifier] = features
                database.upsertFeatureprint(
                    assetId: member.localIdentifier,
                    data: FeaturePrintCodec.encodeScores([
                        features.clarity, features.aesthetics,
                        features.faceQuality, features.saliency,
                    ]),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date()
                )
            }

            scored.append(GroupScoring.score(
                group: group,
                featuresByID: scoresByID,
                hashByID: hashByID,
                embeddingByID: embeddingByID,
                hasUserData: hasUserData
            ))

            machine.setProgress(Double(index + 1) / Double(total))
            publishSnapshot()
            reportProgress()
        }

        snapshotLock.lock()
        scoredGroupsSnapshot = scored
        snapshotLock.unlock()

        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// 原子读取并清零暂停请求。返回置位前的值。
    private func consumePauseRequest() -> Bool {
        snapshotLock.lock()
        let requested = pauseRequested
        pauseRequested = false
        snapshotLock.unlock()
        return requested
    }

    private func publishSnapshot() {
        snapshotLock.lock()
        phaseSnapshot = machine.phase
        progressSnapshot = machine.progress
        snapshotLock.unlock()
    }

    private func reportProgress() {
        snapshotLock.lock()
        let phase = phaseSnapshot
        let progress = progressSnapshot
        snapshotLock.unlock()
        progressHandler?(phase, progress)
    }
}
