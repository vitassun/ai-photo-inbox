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

    private enum SnapshotKeys {
        static let version = "scan.resultsVersion"
        static let assets = "scan.resultAssets"
        static let candidates = "scan.candidateGroups"
        static let scored = "scan.scoredGroups"
        static let lowQuality = "scan.lowQualityCandidates"
        static let largeMedia = "scan.largeMediaCandidates"
    }

    private let machine: ScanStateMachine
    private let photoLibrary: PhotoLibraryServiceProtocol
    private let database: PhotoLibraryDatabase
    private let store: KeyValueStore

    /// 状态机的全部读写都收敛到这条串行队列。
    private let workQueue: DispatchQueue
    /// 快照锁：保护镜像字段与暂停请求标志；绝不在持锁时触碰工作队列。
    private let snapshotLock = NSLock()
    private var phaseSnapshot: ScanPhase = .idle
    private var progressSnapshot: Double = 0
    private var pauseRequested = false
    /// 完成结果变化通知；由 AppEnvironment 接到主线程以刷新 SwiftUI。
    private var resultsChangedHandler: (() -> Void)?

    private var progressHandler: ((ScanPhase, Double) -> Void)?

    /// 注入点：hashing 阶段的图像来源与哈希实现。
    /// 生产构造处传 PhotoKitImageDataProvider + PerceptualHash；
    /// 默认 nil 使 hashing 阶段空转推进（CI 单测注入假实现覆盖真实路径）。
    private let imageDataLoader: (String) -> Data?
    private let hashComputer: (Data) -> String?
    private let embeddingComputer: (Data) -> [Double]?
    /// scoring 阶段的四维特征来源（T08 analyze 的注入点）。
    private let featureAnalyzer: (Data) -> VisionAnalysisResult?
    /// 低质量检测注入（T16）：编码图像数据 → EXIF 字典（夜间白名单豁免判定）。
    private let exifReader: (Data) -> [String: Any]?
    /// 直接读取资产原始编码数据的 EXIF（生产实现用于避免缩略图重编码丢失元数据）。
    /// 保留 exifReader(Data) 兼容测试注入；两者同时提供时优先使用原始读取器。
    private let assetExifReader: ((String) -> [String: Any]?)?
    /// 低质量检测注入（T16）：编码图像数据 → 曝光直方图占比（过曝/欠曝）。
    private let exposureProbe: (Data) -> (over: Double, under: Double)?
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
    /// 低质量候选快照（T16，含夜间豁免标记项）。镜像受 snapshotLock 保护。
    private var lowQualitySnapshot: [LowQualityCandidate] = []
    /// 大媒体候选快照（T17，估算体积降序）。镜像受 snapshotLock 保护。
    private var largeMediaSnapshot: [LargeMediaCandidate] = []
    /// 当前轮次读取到的用户 keep 保护。nil 表示安全数据不可用，不能生成
    /// 自动建议；空集合表示读取成功但目前没有 keep 记录。
    private var keepDecisionIDsForRun: Set<String>?
    private var safetyErrorSnapshot: String?

    /// 仅在 workQueue 上读写。
    private var isDriving = false
    /// 相册在当前扫描轮次中发生变更时置位；本轮不打断，完成后丢弃可能过期的镜像。
    private var pendingLibraryChange = false

    init(
        photoLibrary: PhotoLibraryServiceProtocol,
        database: PhotoLibraryDatabase,
        store: KeyValueStore,
        imageDataLoader: @escaping (String) -> Data? = { _ in nil },
        hashComputer: @escaping (Data) -> String? = { _ in nil },
        embeddingComputer: @escaping (Data) -> [Double]? = { _ in nil },
        featureAnalyzer: @escaping (Data) -> VisionAnalysisResult? = { _ in nil },
        exifReader: @escaping (Data) -> [String: Any]? = { _ in nil },
        assetExifReader: ((String) -> [String: Any]?)? = nil,
        exposureProbe: @escaping (Data) -> (over: Double, under: Double)? = { _ in nil },
        hasUserData: Bool = false,
        workQueue: DispatchQueue = DispatchQueue(label: "com.aiphotoinbox.ScanningEngine", qos: .userInitiated)
    ) {
        self.photoLibrary = photoLibrary
        self.database = database
        self.store = store
        self.workQueue = workQueue
        self.imageDataLoader = imageDataLoader
        self.hashComputer = hashComputer
        self.embeddingComputer = embeddingComputer
        self.featureAnalyzer = featureAnalyzer
        self.exifReader = exifReader
        self.assetExifReader = assetExifReader
        self.exposureProbe = exposureProbe
        self.hasUserData = hasUserData
        self.machine = ScanStateMachine(store: store)
        publishSnapshot()

        // 完成结果保存在 scan_state 中，避免重启后状态显示 done 但三个
        // 清理入口为空。恢复在工作队列异步执行，不能阻塞 App 启动主线程。
        if machine.phase == .done {
            workQueue.async { [weak self] in
                self?.hydrateCompletedSnapshotOnQueue()
            }
        }
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

    /// 安全数据读取失败时的可见错误。失败期间只暂停/收窄建议，不向用户
    /// 显示一个看似完整但可能遗漏 keep 保护的清单。
    var safetyError: String? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return safetyErrorSnapshot
    }

    /// 删除完成后刷新内存视图（T10）：从候选组与评分视图里移除已删 id，
    /// 成员数跌破 2 的组随之解散。须在 workQueue 上调用（经 enqueue 包装）。
    func purgeDeletedFromViews(assetIds: [String], completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let deleted = Set(assetIds)
            self.fetchedRecords.removeAll { deleted.contains($0.localIdentifier) }
            for id in deleted {
                self.hashByID[id] = nil
                self.embeddingByID[id] = nil
                self.scoresByID[id] = nil
            }
            let oldCandidateGroups = self.candidateGroupsOnQueue()
            let oldScoredGroups = self.scoredGroupsOnQueue()
            let protectedIDs = self.keepDecisionIDsOnQueue()

            var keptGroups: [CandidateGroup] = []
            for group in oldCandidateGroups {
                let remaining = group.members.filter { !deleted.contains($0.localIdentifier) }
                if remaining.count >= 2 {
                    keptGroups.append(CandidateGroup(id: group.id, members: remaining, reason: group.reason))
                }
            }
            self.snapshotLock.lock()
            self.candidateGroupsSnapshot = keptGroups
            self.snapshotLock.unlock()

            var keptScored: [ScoredGroup] = []
            for scored in oldScoredGroups {
                let remaining = scored.members.filter { !deleted.contains($0.record.localIdentifier) }
                guard remaining.count >= 2 else { continue }
                // 成员原本已按分数降序排列；首位就是删除后的新 Best Shot。
                let rebuiltMembers = remaining.enumerated().map { index, member -> ScoredMember in
                    ScoredMember(
                        record: member.record,
                        score: member.score,
                        isBestShot: index == 0
                    )
                }
                keptScored.append(ScoredGroup(
                    groupID: scored.groupID,
                    reason: scored.reason,
                    members: rebuiltMembers,
                    preselectableIDs: protectedIDs.map { ids in
                        GroupScoring.preselectableIDs(
                            for: rebuiltMembers,
                            hashByID: self.hashByID,
                            embeddingByID: self.embeddingByID,
                            protectedIDs: ids
                        )
                    } ?? []
                ))
            }
            let deletedIds = deleted
            self.snapshotLock.lock()
            self.scoredGroupsSnapshot = keptScored
            self.lowQualitySnapshot.removeAll { deletedIds.contains($0.record.localIdentifier) }
            self.largeMediaSnapshot.removeAll { deletedIds.contains($0.record.localIdentifier) }
            self.snapshotLock.unlock()
            self.persistSnapshotsOnQueue()
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

    /// 低质量候选快照（T16；含夜间豁免标记项，UI 据此分区/打角标）。
    var lowQualityCandidates: [LowQualityCandidate] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return lowQualitySnapshot
    }

    /// 用户把低质量候选移出（P6 长按反馈）：镜像移除。
    /// decisions 的 user_override 落库由调用方（UI 层）负责。
    func removeLowQualityCandidates(assetIds: [String], completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let removed = Set(assetIds)
            self.snapshotLock.lock()
            self.lowQualitySnapshot.removeAll { removed.contains($0.record.localIdentifier) }
            self.snapshotLock.unlock()
            self.persistSnapshotsOnQueue()
            completion?()
        }
    }

    /// 相册外部变更后的增量失效：更新快照元数据，清掉可能受收藏/编辑/分组
    /// 影响的分析视图，等待下一次扫描重建。扫描正在进行时不打断当前轮，
    /// 下一轮 fetching 会重新拉取全量元数据。
    func refreshAfterLibraryChange(records: [AssetRecord], removedIDs: [String] = []) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let removed = Set(removedIDs)
            let changed = Set(records.map(\.localIdentifier)).union(removed)

            // 先失效缓存和自动裁决，再决定是否延后到本轮扫描结束处理；
            // 后续任何恢复路径都不能读到变更前的特征。
            self.database.removeFeatureprints(assetIds: Array(changed))
            self.database.clearAutomaticDeleteDecisions(assetIds: Array(changed))
            if self.machine.isActive {
                self.pendingLibraryChange = true
                return
            }
            self.pendingLibraryChange = false

            self.fetchedRecords.removeAll { changed.contains($0.localIdentifier) }
            self.fetchedRecords.append(contentsOf: records.filter {
                !removed.contains($0.localIdentifier)
            })
            for id in changed {
                self.hashByID[id] = nil
                self.embeddingByID[id] = nil
                self.scoresByID[id] = nil
            }

            self.snapshotLock.lock()
            self.candidateGroupsSnapshot = []
            self.scoredGroupsSnapshot = []
            self.lowQualitySnapshot = []
            self.largeMediaSnapshot = []
            self.snapshotLock.unlock()
            self.clearPersistedSnapshotsOnQueue()
            self.notifyResultsChanged()

            // 完成状态已经对应旧相册快照；退回 idle 让首页明确要求重新扫描，
            // 避免展示“扫描完成”但内容已经过期。
            if self.machine.phase == .done {
                _ = self.machine.reset()
                self.publishSnapshot()
            }
        }
    }

    /// 大媒体候选快照（T17）。
    var largeMediaCandidates: [LargeMediaCandidate] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return largeMediaSnapshot
    }

    /// 当前扫描结果中可由“全选建议”带入确认框的 id。组建议、低质量和
    /// 大媒体建议统一去重，首页计数与三个详情页共用这一口径。
    var pendingDeletionIDs: Set<String> {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        var ids = Set(scoredGroupsSnapshot.flatMap(\.preselectableIDs))
        ids.formUnion(lowQualitySnapshot.filter(\.canPreselect)
            .map { $0.record.localIdentifier })
        ids.formUnion(largeMediaSnapshot.filter(\.canPreselect)
            .map { $0.record.localIdentifier })
        return ids
    }

    /// 结果镜像不是 ObservableObject；生产装配层用这个轻量回调把完成/删除/
    /// 恢复事件桥接到 SwiftUI。回调在主线程执行，避免页面读到半套快照。
    func setResultsChangedHandler(_ handler: @escaping () -> Void) {
        snapshotLock.lock()
        resultsChangedHandler = handler
        snapshotLock.unlock()
    }

    // MARK: ScanningEngineProtocol

    func runFullScan(progress: @escaping (ScanPhase, Double) -> Void) {
        snapshotLock.lock()
        progressHandler = progress
        pauseRequested = false
        snapshotLock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            switch self.machine.phase {
            case .done:
                // 上一轮已完成 → 全新重扫：复位状态机并清当轮内存快照。
                // （此前该路径静默返回，UI 会永远停在"启动中…"——真机复现的卡死 bug。）
                self.machine.reset()
                self.clearRunSnapshots()
            case .paused:
                // 暂停中的"继续扫描"= 原地续跑，保留断点（此前同样会静默返回）。
                guard self.machine.resume() else { return }
                self.publishSnapshot()
                self.reportProgress()
            default:
                break
            }
            // idle（全新/复位后）清掉非当前版本与旧轮次的特征数据；
            // 当前实现没有资产内容版本，无法证明同一 id 的内容未变，
            // 因而全量重扫必须重新计算。
            if self.machine.phase == .idle {
                // 新一轮全量扫描没有可验证的资产内容版本；清掉旧特征，
                // 以正确性优先，避免同一 id 的修改照片复用旧结果。
                self.database.purgeFeatureprints(keepingFeatureVersion: ScanStateMachine.featureVersion)
                self.database.removeAllFeatureprints()
                self.database.clearAutomaticDeleteDecisions()
            }
            self.startDrivingOnQueue()
        }
    }

    /// 清空当轮内存快照与中间结果（全量重扫的干净起点）。
    /// 仅允许在 workQueue 上调用（与其它快照写路径同队列约束）。
    private func clearRunSnapshots(clearSafetyError: Bool = true) {
        fetchedRecords = []
        hashByID = [:]
        embeddingByID = [:]
        scoresByID = [:]
        keepDecisionIDsForRun = nil
        snapshotLock.lock()
        candidateGroupsSnapshot = []
        scoredGroupsSnapshot = []
        lowQualitySnapshot = []
        largeMediaSnapshot = []
        if clearSafetyError {
            safetyErrorSnapshot = nil
        }
        snapshotLock.unlock()
        clearPersistedSnapshotsOnQueue()
    }

    /// 读取 keep 必须区分“空集合”和“读取失败”。安全保护表不可读时，
    /// 自动建议只能暂停，不能把失败当成没有保护记录。
    private func keepDecisionIDsOnQueue() -> Set<String>? {
        switch database.assetIDsResult(withVerdict: .keep) {
        case .success(let ids):
            snapshotLock.lock()
            safetyErrorSnapshot = nil
            snapshotLock.unlock()
            return ids
        case .failure(let error):
            snapshotLock.lock()
            safetyErrorSnapshot = "无法读取用户保留记录，删除建议已暂停：\(error.localizedDescription)"
            snapshotLock.unlock()
            return nil
        }
    }

    private func pauseForSafetyFailureOnQueue() {
        if machine.isActive {
            machine.pause(reason: "无法读取用户保留记录")
        }
        publishSnapshot()
        reportProgress()
        notifyResultsChanged()
    }

    /// 从已完成扫描保存的值恢复候选镜像。资产元数据必须与保存时一致；
    /// 一旦发现收藏/编辑/尺寸/时间等字段改变，整轮结果作废并回到 idle。
    private func hydrateCompletedSnapshotOnQueue() {
        guard machine.phase == .done else { return }
        guard let version = store.string(forKey: SnapshotKeys.version),
              Int(version) == ScanStateMachine.featureVersion,
              let assetsData = store.string(forKey: SnapshotKeys.assets)?.data(using: .utf8),
              let savedAssets = try? JSONDecoder().decode([AssetRecord].self, from: assetsData),
              let scoredData = store.string(forKey: SnapshotKeys.scored)?.data(using: .utf8),
              let savedScored = try? JSONDecoder().decode([ScoredGroup].self, from: scoredData) else {
            clearRunSnapshots()
            _ = machine.reset()
            publishSnapshot()
            notifyResultsChanged()
            return
        }

        func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let text = store.string(forKey: key),
                  let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }

        guard let restoredCandidates = decode(SnapshotKeys.candidates, as: [CandidateGroup].self),
              let restoredLowQuality = decode(SnapshotKeys.lowQuality, as: [LowQualityCandidate].self),
              let restoredLargeMedia = decode(SnapshotKeys.largeMedia, as: [LargeMediaCandidate].self) else {
            clearRunSnapshots()
            _ = machine.reset()
            publishSnapshot()
            notifyResultsChanged()
            return
        }
        guard let protectedIDs = keepDecisionIDsOnQueue() else {
            clearRunSnapshots(clearSafetyError: false)
            _ = machine.reset()
            publishSnapshot()
            notifyResultsChanged()
            return
        }
        keepDecisionIDsForRun = protectedIDs
        let current = uniqueRecords(
            photoLibrary.fetchAllAssets().filter { !$0.localIdentifier.isEmpty }
        )
        let currentByID = Dictionary(current.map { ($0.localIdentifier, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let changed = savedAssets.count != current.count
            || savedAssets.contains { record in
                guard let currentRecord = currentByID[record.localIdentifier] else { return true }
                return currentRecord != record
            }
        if changed {
            clearRunSnapshots()
            _ = machine.reset()
            publishSnapshot()
            notifyResultsChanged()
            return
        }

        fetchedRecords = current
        hashByID = database.allFeatureprintHashes(featureVersion: ScanStateMachine.featureVersion)
        embeddingByID = database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion)
        scoresByID = database.allFeatureprintScores(featureVersion: ScanStateMachine.featureVersion)
            .compactMapValues { values in
                guard values.count == 4 else { return nil }
                return VisionResultAggregator.aggregate(
                    clarity: values[0], aesthetics: values[1],
                    faceQuality: values[2], saliency: values[3]
                )
            }

        let currentIDs = Set(current.map(\.localIdentifier))
        let filteredScored = savedScored.compactMap { group -> ScoredGroup? in
            guard group.members.allSatisfy({ currentIDs.contains($0.record.localIdentifier) }) else {
                return nil
            }
            // scan_state 是可损坏/可被旧版本写入的外部状态；恢复时重新
            // 应用 SafetyRules 和直接相似阈值，不能盲信持久化的预选 id。
            let safeIDs = GroupScoring.preselectableIDs(
                for: group.members,
                hashByID: hashByID,
                embeddingByID: embeddingByID,
                protectedIDs: protectedIDs
            )
            return ScoredGroup(
                groupID: group.groupID,
                reason: group.reason,
                members: group.members,
                preselectableIDs: safeIDs
            )
        }
        let safeLowQuality = restoredLowQuality.compactMap { candidate -> LowQualityCandidate? in
            guard currentIDs.contains(candidate.record.localIdentifier),
                  !candidate.record.favorite, !candidate.record.isEdited else { return nil }
            return LowQualityCandidate(
                record: candidate.record,
                kind: candidate.kind,
                clarity: candidate.clarity,
                isNightExempt: candidate.isNightExempt,
                isOnlyInGroup: true
            )
        }
        let safeLargeMedia = restoredLargeMedia.compactMap { candidate -> LargeMediaCandidate? in
            guard currentIDs.contains(candidate.record.localIdentifier),
                  !candidate.record.favorite, !candidate.record.isEdited else { return nil }
            return LargeMediaCandidate(
                record: candidate.record,
                estimatedBytes: max(0, candidate.estimatedBytes),
                isOnlyInGroup: true
            )
        }
        snapshotLock.lock()
        candidateGroupsSnapshot = restoredCandidates.filter {
            $0.members.allSatisfy { currentIDs.contains($0.localIdentifier) }
        }
        scoredGroupsSnapshot = filteredScored
        lowQualitySnapshot = safeLowQuality
        largeMediaSnapshot = safeLargeMedia
        snapshotLock.unlock()
        notifyResultsChanged()
    }

    /// 保存完成结果，键值存储只保存 JSON，不复制图像数据。
    private func persistSnapshotsOnQueue() {
        let encoder = JSONEncoder()
        snapshotLock.lock()
        let candidates = candidateGroupsSnapshot
        let scored = scoredGroupsSnapshot
        let lowQuality = lowQualitySnapshot
        let largeMedia = largeMediaSnapshot
        let assets = fetchedRecords
        snapshotLock.unlock()

        guard let assetsData = try? encoder.encode(assets),
              let candidatesData = try? encoder.encode(candidates),
              let scoredData = try? encoder.encode(scored),
              let lowQualityData = try? encoder.encode(lowQuality),
              let largeMediaData = try? encoder.encode(largeMedia),
              let assetsText = String(data: assetsData, encoding: .utf8),
              let candidatesText = String(data: candidatesData, encoding: .utf8),
              let scoredText = String(data: scoredData, encoding: .utf8),
              let lowQualityText = String(data: lowQualityData, encoding: .utf8),
              let largeMediaText = String(data: largeMediaData, encoding: .utf8) else { return }

        store.setString(String(ScanStateMachine.featureVersion), forKey: SnapshotKeys.version)
        store.setString(assetsText, forKey: SnapshotKeys.assets)
        store.setString(candidatesText, forKey: SnapshotKeys.candidates)
        store.setString(scoredText, forKey: SnapshotKeys.scored)
        store.setString(lowQualityText, forKey: SnapshotKeys.lowQuality)
        store.setString(largeMediaText, forKey: SnapshotKeys.largeMedia)
        notifyResultsChanged()
    }

    /// 保存 fetching 完成时的完整资产元数据。候选结果尚未生成时也要保留这份
    /// 基准，以便杀进程恢复时判断旧特征是否仍对应当前相册内容。
    private func persistAssetSnapshotOnQueue() {
        let encoder = JSONEncoder()
        snapshotLock.lock()
        let assets = fetchedRecords
        snapshotLock.unlock()
        guard let data = try? encoder.encode(assets),
              let text = String(data: data, encoding: .utf8) else { return }
        store.setString(String(ScanStateMachine.featureVersion), forKey: SnapshotKeys.version)
        store.setString(text, forKey: SnapshotKeys.assets)
    }

    private func storedAssetSnapshotOnQueue() -> [AssetRecord]? {
        guard let version = store.string(forKey: SnapshotKeys.version),
              Int(version) == ScanStateMachine.featureVersion,
              let text = store.string(forKey: SnapshotKeys.assets),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AssetRecord].self, from: data)
    }

    private func assetSnapshotsMatch(_ lhs: [AssetRecord], _ rhs: [AssetRecord]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let leftByID = Dictionary(lhs.map { ($0.localIdentifier, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let rightByID = Dictionary(rhs.map { ($0.localIdentifier, $0) },
                                   uniquingKeysWith: { first, _ in first })
        return leftByID == rightByID
    }

    private func clearPersistedSnapshotsOnQueue() {
        store.setString(nil, forKey: SnapshotKeys.version)
        store.setString(nil, forKey: SnapshotKeys.assets)
        store.setString(nil, forKey: SnapshotKeys.candidates)
        store.setString(nil, forKey: SnapshotKeys.scored)
        store.setString(nil, forKey: SnapshotKeys.lowQuality)
        store.setString(nil, forKey: SnapshotKeys.largeMedia)
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
        // 杀进程续跑：中间镜像随进程消失，重拉并同步元数据，再从持久化特征重建。
        // fetching 完成时会先写入完整 AssetRecord 快照；若当前相册元数据已经
        // 变化，旧特征无法证明仍有效，安全回退到 hashing 阶段重算。
        if machine.phase == .hashing || machine.phase == .embedding
            || machine.phase == .clustering || machine.phase == .scoring,
           fetchedRecords.isEmpty {
            let currentRecords = uniqueRecords(
                photoLibrary.fetchAllAssets().filter { !$0.localIdentifier.isEmpty }
            )
            let savedRecords = storedAssetSnapshotOnQueue()
            // 没有可比较的资产快照时，不能证明数据库中的特征仍对应当前相册。
            // 兼容旧版本/手工断点要以正确性优先，清掉旧特征后从 hashing 重算。
            let metadataChanged = savedRecords.map { !assetSnapshotsMatch($0, currentRecords) } ?? true

            // 即使没有保存快照（兼容旧版本/手工断点），也要把当前全库同步进
            // assets 表，清理已删除资产及其级联特征，避免恢复后数据库落后。
            database.replaceAssetSnapshot(currentRecords, fetchedAt: Date())
            fetchedRecords = currentRecords

            if metadataChanged {
                database.removeAllFeatureprints()
                database.clearAutomaticDeleteDecisions()
                clearRunSnapshots()
                fetchedRecords = currentRecords
                _ = machine.rewind(to: .hashing)
            }
            persistAssetSnapshotOnQueue()
        }
        hydrateForResumeOnQueue()
        guard !isDriving, machine.isActive else { return }
        isDriving = true
        driveUntilInactive()
        isDriving = false
        // 回调只服务当前一轮；清掉闭包，避免 SwiftUI View 被引擎长期持有形成引用链。
        snapshotLock.lock()
        progressHandler = nil
        snapshotLock.unlock()
        if pendingLibraryChange, machine.phase == .done {
            // 当前轮次使用的是变更前的 fetchedRecords；清掉镜像，避免 UI
            // 在下一次扫描前继续展示过期候选。特征和自动裁决已经在变更回调
            // 中失效，下一轮会从当前相册重新计算。
            pendingLibraryChange = false
            clearRunSnapshots()
            _ = machine.reset()
            publishSnapshot()
        }
    }

    /// 重建进程内中间结果。数据库只保存特征，不保存按当前算法生成的候选组，
    /// 因此恢复时必须按同一组装逻辑重新生成；所有操作只在 workQueue 上执行。
    private func hydrateForResumeOnQueue() {
        guard !fetchedRecords.isEmpty else { return }
        switch machine.phase {
        case .hashing, .embedding, .clustering, .scoring:
            break
        default:
            return
        }

        hashByID = database.allFeatureprintHashes(featureVersion: ScanStateMachine.featureVersion)
        let hashGroups = CandidateGrouper.groups(from: fetchedRecords, hashByID: hashByID)
        setCandidateGroupsSnapshot(hashGroups)

        guard machine.phase == .embedding || machine.phase == .clustering || machine.phase == .scoring else {
            return
        }

        embeddingByID = database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion)
        guard machine.phase == .clustering || machine.phase == .scoring else { return }

        let claimed = Set(hashGroups.flatMap(\.memberIDs))
        let embeddingPending = fetchedRecords.filter { !claimed.contains($0.localIdentifier) }
        let hasMissingEmbedding = embeddingPending.contains {
            guard let vector = embeddingByID[$0.localIdentifier] else { return true }
            return !EmbeddingMath.isUsable(vector)
        }
        if hasMissingEmbedding {
            _ = machine.rewind(to: .embedding)
            setCandidateGroupsSnapshot(hashGroups)
            return
        }

        setCandidateGroupsSnapshot(groupsIncludingEmbeddings(baseGroups: hashGroups))
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
        let assets = uniqueRecords(
            photoLibrary.fetchAllAssets().filter { !$0.localIdentifier.isEmpty }
        )
        fetchedRecords = assets
        hashByID = [:]
        embeddingByID = [:]
        scoresByID = [:]
        let fetchedAt = Date()
        if consumePauseRequest() {
            machine.pause(reason: "用户暂停")
            return false
        }
        // 全量快照同时负责清理相册外部删除但尚未收到 change observer 事件的旧行。
        database.replaceAssetSnapshot(assets, fetchedAt: fetchedAt)
        let total = max(assets.count, 1)
        for (index, _) in assets.enumerated() {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }
            machine.setProgress(Double(index + 1) / Double(total))
            if (index + 1) % 200 == 0 || index + 1 == assets.count {
                publishSnapshot()
                reportProgress()
            }
        }
        // 先保存全量 AssetRecord，再推进阶段；这样在 hashing/embedding 等
        // 后续阶段被杀时可以比较收藏、编辑、尺寸、时间、地理和 Live Photo 等字段。
        persistAssetSnapshotOnQueue()
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
            throttleForThermalPressure()
            machine.setProgress(Double(index + 1) / Double(total))
            if (index + 1) % 200 == 0 || index + 1 == fetchedRecords.count {
                publishSnapshot()
                reportProgress()
            }
        }

        let groups = CandidateGrouper.groups(from: fetchedRecords, hashByID: hashByID)
        setCandidateGroupsSnapshot(groups)

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

        let claimed = Set(candidateGroupsOnQueue().flatMap(\.memberIDs))
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
                if EmbeddingMath.isUsable(vector) {
                    embeddingByID[record.localIdentifier] = vector
                    database.upsertFeatureprint(
                        assetId: record.localIdentifier,
                        data: FeaturePrintCodec.encodeEmbedding(vector),
                        featureVersion: ScanStateMachine.featureVersion,
                        computedAt: Date()
                    )
                }
            }
            throttleForThermalPressure()
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
        let groups = groupsIncludingEmbeddings(baseGroups: candidateGroupsOnQueue())
        setCandidateGroupsSnapshot(groups)

        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// 在 pHash 基础组上追加 embedding 连通分量。CandidateGrouper 已按媒体类型
    /// 切分，且无效/零向量不会被当作“全部相似”。
    private func groupsIncludingEmbeddings(baseGroups: [CandidateGroup]) -> [CandidateGroup] {
        var groups = baseGroups

        for unit in CandidateGrouper.timeGeoUnits(from: fetchedRecords) {
            let claimed = Set(groups.flatMap(\.memberIDs))
            let members = unit.members.filter {
                guard !claimed.contains($0.localIdentifier),
                      let vector = embeddingByID[$0.localIdentifier] else { return false }
                return EmbeddingMath.isUsable(vector)
            }
            guard members.count >= 2 else { continue }

            let vectors = members.compactMap { member -> (id: String, vector: [Double])? in
                guard let vector = embeddingByID[member.localIdentifier], EmbeddingMath.isUsable(vector) else {
                    return nil
                }
                return (id: member.localIdentifier, vector: vector)
            }
            for component in EmbeddingClusterer.components(of: vectors) where component.count >= 2 {
                let ids = Set(component)
                let groupMembers = members.filter { ids.contains($0.localIdentifier) }
                guard let first = groupMembers.first else { continue }
                groups.append(
                    CandidateGroup(
                        id: "cand-\(unit.bucketIndex)-emb-\(first.localIdentifier)",
                        members: groupMembers,
                        reason: "时间×地理×embedding"
                    )
                )
            }
        }
        return groups
    }

    /// scoring：逐组跑 GroupScoring（KeepScore 接线 + 冗余度 + SafetyRules 过滤）
    /// → Best Shot 标记 → 预删除候选集。缺特征的资产按中性值参与评分。
    private func runScoringStage() -> Bool {
        guard let protectedIDs = keepDecisionIDsOnQueue() else {
            pauseForSafetyFailureOnQueue()
            return false
        }
        keepDecisionIDsForRun = protectedIDs

        // 复用已持久化的分数（信封 kind=3）。
        for (assetId, values) in database.allFeatureprintScores(featureVersion: ScanStateMachine.featureVersion)
        where values.count == 4 {
            scoresByID[assetId] = VisionResultAggregator.aggregate(
                clarity: values[0], aesthetics: values[1],
                faceQuality: values[2], saliency: values[3]
            )
        }

        let groups = candidateGroupsOnQueue()
        let total = max(groups.count, 1)
        var scored: [ScoredGroup] = []
        for (index, group) in groups.enumerated() {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }

            // 缺分数的成员补算（经注入的分析器；失败回退中性值由聚合层保证）。
            for member in group.members where scoresByID[member.localIdentifier] == nil {
                guard let data = imageDataLoader(member.localIdentifier),
                      let features = featureAnalyzer(data) else { continue }
                let sanitized = VisionResultAggregator.aggregate(
                    clarity: features.clarity,
                    aesthetics: features.aesthetics,
                    faceQuality: features.faceQuality,
                    saliency: features.saliency
                )
                scoresByID[member.localIdentifier] = sanitized
                database.upsertFeatureprint(
                    assetId: member.localIdentifier,
                    data: FeaturePrintCodec.encodeScores([
                        sanitized.clarity, sanitized.aesthetics,
                        sanitized.faceQuality, sanitized.saliency,
                    ]),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date()
                )
            }

            let scoredGroup = GroupScoring.score(
                group: group,
                featuresByID: scoresByID,
                hashByID: hashByID,
                embeddingByID: embeddingByID,
                hasUserData: hasUserData,
                protectedIDs: protectedIDs
            )
            // 用户在此前扫描中明确保留的资产可继续展示，但永不重新成为
            // 自动预删除候选；将历史保护应用在评分输出的最后一道边界。
            scored.append(ScoredGroup(
                groupID: scoredGroup.groupID,
                reason: scoredGroup.reason,
                members: scoredGroup.members,
                preselectableIDs: scoredGroup.preselectableIDs
            ))

            throttleForThermalPressure()
            machine.setProgress(Double(index + 1) / Double(total))
            publishSnapshot()
            reportProgress()
        }

        setScoredGroupsSnapshot(scored)

        guard detectLowQuality() else { return false }
        guard detectLargeMedia() else { return false }
        persistSnapshotsOnQueue()

        machine.advance()
        publishSnapshot()
        reportProgress()
        return true
    }

    /// 低质量检测 pass（T16）：未被相似组认领的 image 资产，clarity 阈值 +
    /// 曝光直方图三分支判定；EXIF 夜间白名单命中只打豁免标（红线 6：永不进
    /// 预选集合，不落删除裁决）。裁决幂等：已有用户 keep（user_override）的
    /// 资产不再自动改写。
    /// 成本注记：每个未认领资产多一次缩略图读取（曝光探测）；V1 先正确后省，
    /// 大库优化属后续迭代（可与 hashing 阶段合并采样）。
    private func detectLowQuality() -> Bool {
        let claimed = Set(candidateGroupsOnQueue().flatMap(\.memberIDs))
        guard let protectedIDs = keepDecisionIDsForRun else {
            pauseForSafetyFailureOnQueue()
            return false
        }
        var detected: [LowQualityCandidate] = []

        for record in fetchedRecords {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }
            guard !claimed.contains(record.localIdentifier),
                  record.mediaType == .image,
                  !record.favorite, !record.isEdited else { continue }

            let assetId = record.localIdentifier
            // 用户明确保留/移出候选的资产在后续重扫中也不应被自动加回。
            guard !protectedIDs.contains(assetId) else { continue }
            let imageData = imageDataLoader(assetId)

            // 特征补算（与 scoring 阶段同一信封格式落表，续扫复用）。
            if scoresByID[assetId] == nil,
               let data = imageData,
               let features = featureAnalyzer(data) {
                let sanitized = VisionResultAggregator.aggregate(
                    clarity: features.clarity,
                    aesthetics: features.aesthetics,
                    faceQuality: features.faceQuality,
                    saliency: features.saliency
                )
                scoresByID[assetId] = sanitized
                database.upsertFeatureprint(
                    assetId: assetId,
                    data: FeaturePrintCodec.encodeScores([
                        sanitized.clarity, sanitized.aesthetics,
                        sanitized.faceQuality, sanitized.saliency,
                    ]),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date()
                )
            }
            let clarity = scoresByID[assetId]?.clarity ?? 0.5

            // 曝光探测（注入实现；缺省 nil → 只按模糊判）。
            var overRatio: Double?
            var underRatio: Double?
            if let data = imageData, let probe = exposureProbe(data) {
                overRatio = probe.over
                underRatio = probe.under
            }

            guard let kind = LowQualityDetector.detect(
                clarity: clarity,
                overRatio: overRatio,
                underRatio: underRatio
            ) else { continue }

            // EXIF 夜间白名单（红线 6）：命中 → 豁免标，永不预选、不落删除裁决。
            var isNightExempt = false
            if let exif = assetExifReader?(assetId) {
                isNightExempt = NightWhitelist.isNightLongExposure(exif)
            } else if let data = imageData, let exif = exifReader(data) {
                isNightExempt = NightWhitelist.isNightLongExposure(exif)
            }

            let candidate = LowQualityCandidate(
                record: record, kind: kind, clarity: clarity,
                isNightExempt: isNightExempt, isOnlyInGroup: true
            )
            detected.append(candidate)

            // 未被相似组认领的资产没有已知替代品。它可以展示并允许用户
            // 手动勾选，但永远不自动落 delete 裁决或进入全选建议。
            if candidate.canPreselect {
                database.setDecision(
                    assetId: assetId,
                    verdict: .delete,
                    reason: "low_quality:\(kind.rawValue)",
                    decidedAt: Date()
                )
            }
            throttleForThermalPressure()
        }

        snapshotLock.lock()
        lowQualitySnapshot = detected
        snapshotLock.unlock()
        return true
    }

    /// 大媒体清理 pass（T17）：估算体积 ≥ 阈值、未被相似组认领的资产
    /// （收藏/编辑过由 LargeMediaFilter 内部红线过滤）。裁决幂等口径与
    /// 低质量 pass 一致：用户 keep 不改写。估算值同步落 assets.estimated_bytes。
    private func detectLargeMedia() -> Bool {
        let claimed = Set(candidateGroupsOnQueue().flatMap(\.memberIDs))
        guard let protectedIDs = keepDecisionIDsForRun else {
            pauseForSafetyFailureOnQueue()
            return false
        }
        let candidates = LargeMediaFilter.candidates(
            from: fetchedRecords,
            idsInCandidateGroups: claimed,
            idsWithKeepDecision: protectedIDs
        )

        let safeCandidates = candidates.map { candidate in
            LargeMediaCandidate(
                record: candidate.record,
                estimatedBytes: candidate.estimatedBytes,
                isOnlyInGroup: true
            )
        }

        for candidate in safeCandidates {
            if consumePauseRequest() {
                machine.pause(reason: "用户暂停")
                return false
            }
            // 未下载的 iCloud 原件只做信息展示，页面不可勾选，也不应制造
            // 一个用户无法执行的待确认删除裁决。
            guard candidate.record.locallyAvailable else { continue }
            let assetId = candidate.record.localIdentifier
            if candidate.canPreselect {
                database.setDecision(
                    assetId: assetId,
                    verdict: .delete,
                    reason: "large_media",
                    decidedAt: Date()
                )
            }
            throttleForThermalPressure()
        }

        snapshotLock.lock()
        largeMediaSnapshot = safeCandidates
        snapshotLock.unlock()
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

    private func notifyResultsChanged() {
        snapshotLock.lock()
        let handler = resultsChangedHandler
        snapshotLock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }

    /// Vision/图像解码在高温设备上会放大卡顿与系统降频。扫描仍保持可暂停，
    /// 这里只在系统报告 serious/critical 时让出极短时间；常温路径零额外等待。
    private func throttleForThermalPressure() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            Thread.sleep(forTimeInterval: 0.02)
        case .critical:
            Thread.sleep(forTimeInterval: 0.10)
        default:
            break
        }
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
        let handler = progressHandler
        snapshotLock.unlock()
        handler?(phase, progress)
    }

    /// workQueue 内部读取快照的统一入口，避免与 UI/删除回调并发时数据竞争。
    private func candidateGroupsOnQueue() -> [CandidateGroup] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return candidateGroupsSnapshot
    }

    /// PhotoKit 通常保证 localIdentifier 唯一；协议假实现、迁移数据或
    /// 受限权限边界出现重复时仍需在进入 UI/数据库前去重，避免 ForEach
    /// 重复 id 与主键覆盖造成不确定结果。
    private func uniqueRecords(_ records: [AssetRecord]) -> [AssetRecord] {
        var seen = Set<String>()
        var result: [AssetRecord] = []
        result.reserveCapacity(records.count)
        for record in records where seen.insert(record.localIdentifier).inserted {
            result.append(record)
        }
        return result
    }

    private func scoredGroupsOnQueue() -> [ScoredGroup] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return scoredGroupsSnapshot
    }

    private func setCandidateGroupsSnapshot(_ groups: [CandidateGroup]) {
        snapshotLock.lock()
        candidateGroupsSnapshot = groups
        snapshotLock.unlock()
    }

    private func setScoredGroupsSnapshot(_ groups: [ScoredGroup]) {
        snapshotLock.lock()
        scoredGroupsSnapshot = groups
        snapshotLock.unlock()
    }
}
