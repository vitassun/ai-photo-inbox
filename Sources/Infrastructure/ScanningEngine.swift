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

/// 扫描结果快照专用的持久化模型。GPS 只用于当前轮次的分组，
/// 不进入恢复 JSON；修改版本仍保留，用来验证特征是否新鲜。
private struct PersistedAssetRecord: Codable, Equatable {
    let localIdentifier: String
    let favorite: Bool
    let isEdited: Bool
    let mediaType: AssetMediaType
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double
    let creationDate: Date?
    let modificationDate: Date?
    let isScreenshot: Bool
    let isLivePhoto: Bool
    let localAvailability: AssetLocalAvailability

    init(_ record: AssetRecord) {
        localIdentifier = record.localIdentifier
        favorite = record.favorite
        isEdited = record.isEdited
        mediaType = record.mediaType
        pixelWidth = record.pixelWidth
        pixelHeight = record.pixelHeight
        duration = record.duration
        creationDate = record.creationDate
        modificationDate = record.modificationDate
        isScreenshot = record.isScreenshot
        isLivePhoto = record.isLivePhoto
        localAvailability = record.localAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case localIdentifier, favorite, isEdited, mediaType, pixelWidth,
             pixelHeight, duration, creationDate, modificationDate,
             isScreenshot, isLivePhoto, localAvailability, locallyAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localIdentifier = try container.decode(String.self, forKey: .localIdentifier)
        favorite = try container.decode(Bool.self, forKey: .favorite)
        isEdited = try container.decode(Bool.self, forKey: .isEdited)
        mediaType = try container.decode(AssetMediaType.self, forKey: .mediaType)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        duration = try container.decode(Double.self, forKey: .duration)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        isScreenshot = try container.decode(Bool.self, forKey: .isScreenshot)
        isLivePhoto = try container.decode(Bool.self, forKey: .isLivePhoto)
        if let value = try container.decodeIfPresent(AssetLocalAvailability.self, forKey: .localAvailability) {
            localAvailability = value
        } else {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .locallyAvailable)
            localAvailability = legacy == false ? .notDownloaded : .available
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localIdentifier, forKey: .localIdentifier)
        try container.encode(favorite, forKey: .favorite)
        try container.encode(isEdited, forKey: .isEdited)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(creationDate, forKey: .creationDate)
        try container.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try container.encode(isScreenshot, forKey: .isScreenshot)
        try container.encode(isLivePhoto, forKey: .isLivePhoto)
        try container.encode(localAvailability, forKey: .localAvailability)
        try container.encode(localAvailability.isAvailable, forKey: .locallyAvailable)
    }

    func matches(_ record: AssetRecord) -> Bool {
        self == PersistedAssetRecord(record)
    }
}

final class ScanningEngine: ScanningEngineProtocol {

    private enum SnapshotKeys {
        static let schema = "scan.resultsSchema"
        static let version = "scan.resultsVersion"
        static let assets = "scan.resultAssets"
        static let candidates = "scan.candidateGroups"
        static let scored = "scan.scoredGroups"
        static let lowQuality = "scan.lowQualityCandidates"
        static let largeMedia = "scan.largeMediaCandidates"
        static let round = "scan.resultRound"
        static let complete = "scan.resultComplete"
        /// 待分析资产集合（增量扫描语义）。保存被相册变更影响、尚未重新
        /// 分析完成的资产 id 与其当前版本。恢复时按版本差量重算，而不是
        /// 只要可见这套"待更新"状态就无法声明全库已扫描。
        static let pending = "scan.pendingAnalysis"
    }

    private static let snapshotSchemaVersion = 3

    /// 单次队列轮次内最多连续推进的批次数。
    /// 取较大值让中小相册一轮跑完（调用方一次队列屏障即可确认结束），
    /// 同时保证超大相册每处理这么多批就让出一次工作队列。
    private static let maxBatchesPerTurn = 4_096

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
    /// 有限容量的缩略图缓存：hash/embedding/评分/质量检测尽量复用同一份
    /// 输入，同时避免把整库原图长期留在内存。
    private var imageDataCache: [String: Data] = [:]
    private var imageDataCacheOrder: [String] = []
    private var imageDataCacheBytes = 0
    private let maxImageDataCacheBytes = 32 * 1024 * 1024
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
    private var persistenceErrorSnapshot: String?
    /// 完成快照在启动后异步恢复期间为 true。UI 不能把尚未装载的空镜像
    /// 当成“没有待处理项”，也不能在恢复尚未结束时启动新一轮扫描。
    private var restoringResultsSnapshot = false

    /// 仅在 workQueue 上读写。
    private var isDriving = false
    /// 防止批次调度重入：已排队下一批时不再重复入队。仅在 workQueue 上读写。
    private var isSchedulingNextBatch = false
    /// 相册在当前扫描轮次中发生变更时置位；本轮不打断，完成后丢弃可能过期的镜像。
    private var pendingLibraryChange = false
    private var pendingChangedIDs: Set<String> = []
    private var pendingChangedRecords: [AssetRecord] = []
    /// 批次游标：记录各阶段已处理到的位置，使"执行一批"可跨调度调用延续。
    /// 仅在 workQueue 上读写。
    private var fetchCursor = 0
    /// 扫描轮次号。过期批次（轮次已推进）不得把结果写回快照。
    private var scanEpoch: Int = 0
    /// 当前批次所属的扫描轮次。`driveUntilInactive()` 在每批开头比对
    /// `scanEpoch`，不一致即判定为过期批次并整体放弃。
    /// 只有一轮真正收官（`finishDrivingIfNeededOnQueue`）才会清零。
    private var activeBatchEpoch: Int = 0

    /// 阶段内部游标：把每个阶段的内层工作也切成有限批次，而不是只拆外围循环。
    /// 键为阶段，值为该阶段已处理到的资产/组序号。阶段结束或换轮时清空。
    ///
    /// scoring 阶段里还串行跑了两个检测 pass（低质量、大媒体）。它们不是
    /// `ScanPhase` 的成员，但同样需要独立游标，用 `stageKey` 统一成字符串键。
    private var stageCursors: [String: Int] = [:]
    /// 本轮 fetching 时定下的资产版本表（id → modificationDate）。
    /// 各阶段写库前用它校验：资产在批次之间被修改过就不允许落旧特征。
    private var stageAssetVersions: [String: Date?] = [:]
    /// 版本校验失败（资产在批次间隙被修改）的资产 id。
    /// 本批次不再继续处理它们，等下一轮 fetching 以新版本重算。
    private var expiredAssetIDs: Set<String> = []

    /// 待分析资产集合（增量分析语义）：相册变更影响、但尚未重新分析完成的
    /// 资产 id → 变更后应达到的版本（modificationDate）。
    ///
    /// 与 `pendingChangedIDs` 的区别：那一个只是"本次扫描进行中收到的变更"
    /// 的临时缓冲，扫描一结束就消费掉；这一份是**持久化**的欠账，决定
    /// UI 能否声明"全库已扫描"，也是重启后差量恢复的依据。
    /// 所有读写都在 `workQueue` 上；UI 侧通过 `pendingAnalysisSnapshot` 只读镜像。
    private var pendingAnalysis: [String: Date?] = [:]
    /// `pendingAnalysis` 的线程安全只读镜像，供 UI 线程判断"结果待更新"。
    private var pendingAnalysisSnapshot: [String: Date?] = [:]

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
            snapshotLock.lock()
            restoringResultsSnapshot = true
            snapshotLock.unlock()
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

    /// 关键扫描快照落盘失败时的可见错误。失败不会被当作扫描完成，
    /// 用户可以在释放空间后重试。
    var persistenceError: String? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return persistenceErrorSnapshot
    }

    var isRestoringResults: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return restoringResultsSnapshot
    }

    /// 是否存在尚未分析完成、结果待更新的资产。
    ///
    /// 首页据此显示"结果待更新"，且**不得**声明全库已扫描——只要这份欠账
    /// 不为空，候选组/低质量/大媒体三处结果就都还可能是旧的。
    var hasPendingAnalysis: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return !pendingAnalysisSnapshot.isEmpty
    }

    /// 待分析资产数量，用于首页展示具体欠了多少张。
    var pendingAnalysisCount: Int {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return pendingAnalysisSnapshot.count
    }

    /// 结果是否处于"完整可用"状态：扫描到 done、已完成快照恢复、
    /// 且没有任何待分析欠账。三个条件缺一不可。
    var isResultSetComplete: Bool {
        guard state == .done, !isRestoringResults else { return false }
        return !hasPendingAnalysis
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
                self.removeCachedImageOnQueue(id)
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

    /// 用户在相似组页明确保留后，从所有当前结果镜像中移除该资产。
    /// 只收窄现有建议，不在没有完整特征的情况下凭空生成新建议；下一轮扫描
    /// 会重新评估撤销保留的资产。
    func removeScoredCandidates(assetIds: [String], completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let removed = Set(assetIds)
            guard !removed.isEmpty else {
                completion?()
                return
            }

            let keepRead = self.database.assetIDsResult(withVerdict: .keep)
            let protectedIDs: Set<String>?
            if case .success(let ids) = keepRead {
                protectedIDs = ids
            } else {
                protectedIDs = nil
                self.setPersistenceErrorOnQueue("无法读取保留记录，剩余建议已暂停自动选择")
            }

            self.snapshotLock.lock()
            self.candidateGroupsSnapshot = self.candidateGroupsSnapshot.compactMap { group in
                let remaining = group.members.filter {
                    !removed.contains($0.localIdentifier)
                }
                guard remaining.count >= 2 else { return nil }
                return CandidateGroup(
                    id: group.id,
                    members: remaining,
                    reason: group.reason
                )
            }
            self.scoredGroupsSnapshot = self.scoredGroupsSnapshot.compactMap { group in
                let remaining = group.members.filter {
                    !removed.contains($0.record.localIdentifier)
                }
                guard remaining.count >= 2 else { return nil }
                let rebuiltMembers = remaining.enumerated().map { index, member in
                    ScoredMember(
                        record: member.record,
                        score: member.score,
                        isBestShot: index == 0
                    )
                }
                let newBestID = rebuiltMembers.first?.record.localIdentifier
                let remainingIDs = Set(remaining.map { $0.record.localIdentifier })
                let safePreselectable = protectedIDs.map { ids in
                    group.preselectableIDs.filter {
                        remainingIDs.contains($0)
                            && $0 != newBestID
                            && !ids.contains($0)
                    }
                } ?? []
                return ScoredGroup(
                    groupID: group.groupID,
                    reason: group.reason,
                    members: rebuiltMembers,
                    preselectableIDs: safePreselectable
                )
            }
            self.lowQualitySnapshot.removeAll {
                removed.contains($0.record.localIdentifier)
            }
            self.largeMediaSnapshot.removeAll {
                removed.contains($0.record.localIdentifier)
            }
            self.snapshotLock.unlock()
            _ = self.persistSnapshotsOnQueue()
            self.notifyResultsChanged()
            completion?()
        }
    }

    /// 用户在大媒体页明确保留后，立即从当前镜像移出；撤销入口只撤销
    /// keep 记录，下一轮扫描再重新评估，避免在本轮把结果偷偷加回来。
    func removeLargeMediaCandidates(assetIds: [String], completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let removed = Set(assetIds)
            self.snapshotLock.lock()
            self.largeMediaSnapshot.removeAll { removed.contains($0.record.localIdentifier) }
            self.snapshotLock.unlock()
            _ = self.persistSnapshotsOnQueue()
            completion?()
        }
    }

    /// 相册外部变更后的增量失效：更新快照元数据，清掉可能受收藏/编辑/分组
    /// 影响的分析视图，等待下一次扫描重建。扫描正在进行时不打断当前轮，
    /// 下一轮 fetching 会重新拉取全量元数据。
    func refreshAfterLibraryChange(records: [AssetRecord], removedIDs: [String] = []) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let changed = Set(records.map(\.localIdentifier)).union(removedIDs)

            // 先把欠账登记下来再清缓存：任何后续失败路径（清理失败、
            // 保存失败）都不能让这批变更"悄悄消失"，否则 UI 会拿旧结果
            // 声明全库已扫描。
            self.markPendingAnalysisOnQueue(records: records, removedIDs: removedIDs)

            // 先失效缓存和自动裁决，再决定是否延后到本轮扫描结束处理；
            // 后续任何恢复路径都不能读到变更前的特征。
            guard self.database.removeFeatureprints(assetIds: Array(changed)),
                  self.database.clearAutomaticDeleteDecisions(assetIds: Array(changed)) else {
                // 清理失败：欠账必须落盘，让下次启动的差量恢复接手。
                _ = self.persistSnapshotsOnQueue()
                self.setPersistenceErrorOnQueue("相册变更的旧分析结果清理失败，请检查存储空间后重试")
                self.pauseForPersistenceFailureOnQueue()
                return
            }
            if self.machine.isActive {
                self.pendingLibraryChange = true
                self.pendingChangedIDs.formUnion(changed)
                self.pendingChangedRecords.append(contentsOf: records)
                // 扫描进行中也要让 UI 看到"结果待更新"。
                self.syncPendingAnalysisSnapshotOnQueue()
                self.notifyResultsChanged()
                return
            }

            self.pendingLibraryChange = false
            self.pendingChangedIDs = []
            self.pendingChangedRecords = []
            self.invalidateViewsForChangedIDsOnQueue(
                changed,
                replacementRecords: records
            )
            self.notifyResultsChanged()
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
                // 复位写盘失败同样不能继续：否则新一轮的结果会挂在一个
                // 没保存下来的旧 done 阶段上。
                guard self.machine.reset() else {
                    self.setPersistenceErrorOnQueue(
                        self.machine.lastPersistenceError ?? "扫描状态复位失败，请检查存储空间后重试"
                    )
                    return
                }
                self.clearRunSnapshots()
                self.beginNewSnapshotRoundOnQueue()
            case .paused:
                // 暂停中的"继续扫描"= 原地续跑，保留断点（此前同样会静默返回）。
                guard self.machine.resume() else {
                    self.setPersistenceErrorOnQueue(
                        self.machine.lastPersistenceError ?? "扫描状态恢复失败，请检查存储空间后重试"
                    )
                    return
                }
                self.publishSnapshot()
                self.reportProgress()
            default:
                break
            }
            // idle（全新/复位后）清掉非当前版本的特征数据。
            // 全量扫描也**保留仍然匹配的特征**：只清除"内容版本对不上"或
            // 已不在相册里的资产。这样一次完整重建不会把用户已算过的
            // hash/embedding/score 全部丢进回收站，重扫成本可控。
            if self.machine.phase == .idle {
                if self.store.string(forKey: SnapshotKeys.round) == nil {
                    self.beginNewSnapshotRoundOnQueue()
                }
                guard self.database.purgeFeatureprints(keepingFeatureVersion: ScanStateMachine.featureVersion) else {
                    self.setPersistenceErrorOnQueue("旧分析结果清理失败，请检查存储空间后重试")
                    self.pauseForPersistenceFailureOnQueue()
                    return
                }
                // 版本对得上、但资产内容已经变了的特征不能复用。这里用
                // 已落盘的资产快照做差量比对，只清这批过期特征；
                // 没有可比较的快照时（旧版本升级 / 手工断点）无法证明
                // 任何特征仍有效，安全回退到全清。
                if let saved = self.storedAssetSnapshotOnQueue() {
                    let currentRecords = self.uniqueRecords(
                        self.photoLibrary.fetchAllAssets().filter { !$0.localIdentifier.isEmpty }
                    )
                    let currentByID = Dictionary(
                        currentRecords.map { ($0.localIdentifier, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let staleIDs = saved.compactMap { record -> String? in
                        guard let now = currentByID[record.localIdentifier] else {
                            return record.localIdentifier
                        }
                        return record.matches(now) ? nil : record.localIdentifier
                    }
                    let purgedFeatures = staleIDs.isEmpty
                        || self.database.removeFeatureprints(assetIds: staleIDs)
                    // staleIDs 为空时不能把 nil 传下去——nil 语义是"全清"，
                    // 会把用户已确认之外的全部建议抹掉。空数组才是 no-op。
                    guard purgedFeatures,
                          self.database.clearAutomaticDeleteDecisions(assetIds: staleIDs) else {
                        self.setPersistenceErrorOnQueue("旧分析结果清理失败，请检查存储空间后重试")
                        self.pauseForPersistenceFailureOnQueue()
                        return
                    }
                } else {
                    guard self.database.removeAllFeatureprints(),
                          self.database.clearAutomaticDeleteDecisions() else {
                        self.setPersistenceErrorOnQueue("旧分析结果清理失败，请检查存储空间后重试")
                        self.pauseForPersistenceFailureOnQueue()
                        return
                    }
                }
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
        imageDataCache.removeAll(keepingCapacity: true)
        imageDataCacheOrder.removeAll(keepingCapacity: true)
        imageDataCacheBytes = 0
        keepDecisionIDsForRun = nil
        snapshotLock.lock()
        candidateGroupsSnapshot = []
        scoredGroupsSnapshot = []
        lowQualitySnapshot = []
        largeMediaSnapshot = []
        if clearSafetyError {
            safetyErrorSnapshot = nil
        }
        persistenceErrorSnapshot = nil
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
            pauseCheckedOnQueue(reason: "无法读取用户保留记录")
        }
        publishSnapshot()
        reportProgress()
        notifyResultsChanged()
    }

    private func pauseForPersistenceFailureOnQueue() {
        if machine.isActive {
            pauseCheckedOnQueue(reason: "扫描结果保存失败")
        }
        publishSnapshot()
        reportProgress()
        notifyResultsChanged()
    }

    /// 从已完成扫描保存的值恢复候选镜像。资产元数据必须与保存时一致；
    /// 一旦发现收藏/编辑/尺寸/时间等字段改变，整轮结果作废并回到 idle。
    ///
    /// 恢复语义按"差量优先"设计：
    /// 1. 快照格式/版本不兼容或损坏 → 全量重建（清特征、回 idle）；
    /// 2. 相册与快照有差异 → 只让差异部分失效，其余结果保留，
    ///    同时把差异登记为待分析欠账，由增量扫描补齐；
    /// 3. 完全一致且欠账为空 → 直接可用，声明全库已扫描。
    private func hydrateCompletedSnapshotOnQueue() {
        guard machine.phase == .done else { return }
        defer {
            snapshotLock.lock()
            restoringResultsSnapshot = false
            snapshotLock.unlock()
            notifyResultsChanged()
        }
        // 先把持久化的待分析欠账读回来：即使后续任何分支失败，
        // UI 也不能在欠账存在时显示"已扫描完成"。
        pendingAnalysis = decodePendingAnalysis(store.string(forKey: SnapshotKeys.pending))
        syncPendingAnalysisSnapshotOnQueue()

        guard let version = store.string(forKey: SnapshotKeys.version),
              Int(version) == ScanStateMachine.featureVersion,
              store.string(forKey: SnapshotKeys.schema)
                == String(Self.snapshotSchemaVersion),
              store.string(forKey: SnapshotKeys.complete) == "1",
              store.string(forKey: SnapshotKeys.round) != nil,
              let assetsData = store.string(forKey: SnapshotKeys.assets)?.data(using: .utf8),
              let savedAssets = try? JSONDecoder().decode([PersistedAssetRecord].self, from: assetsData),
              let scoredData = store.string(forKey: SnapshotKeys.scored)?.data(using: .utf8),
              let savedScored = try? JSONDecoder().decode([ScoredGroup].self, from: scoredData) else {
            // 快照格式不兼容或损坏：这是唯一需要全量重建的场景。
            fullRebuildOnQueue()
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
            // 结果体损坏、无法解析：快照本身不可信，走全量重建。
            fullRebuildOnQueue()
            return
        }
        guard let protectedIDs = keepDecisionIDsOnQueue() else {
            // 安全数据读不出来：不清结果（保留可见性），只暂停并报错。
            clearRunSnapshots(clearSafetyError: false)
            if !machine.reset(), let error = machine.lastPersistenceError {
                // 复位写盘失败：内存已回到 idle，如实暴露错误让用户重试。
                setPersistenceErrorOnQueue(error)
            }
            publishSnapshot()
            notifyResultsChanged()
            return
        }
        keepDecisionIDsForRun = protectedIDs
        let current = uniqueRecords(
            photoLibrary.fetchAllAssets().filter { !$0.localIdentifier.isEmpty }
        )
        // 差量比对：找出相对快照"新增 / 修改 / 删除"的资产。
        // 与旧实现的关键差别：不再因为存在任何差异就把整轮结果作废，
        // 而是只让差异部分失效并登记欠账，无关组原样保留。
        let savedByID = Dictionary(
            savedAssets.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByID = Dictionary(
            current.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changedIDs = Set<String>()
        var removedIDs = Set<String>()
        for record in savedAssets {
            guard let currentRecord = currentByID[record.localIdentifier] else {
                // 快照里有、相册里没有 → 删除。
                removedIDs.insert(record.localIdentifier)
                changedIDs.insert(record.localIdentifier)
                continue
            }
            if !record.matches(currentRecord) {
                // 元数据变了（收藏/编辑/尺寸/时间/地理等）→ 修改。
                changedIDs.insert(record.localIdentifier)
            }
        }
        for record in current where savedByID[record.localIdentifier] == nil {
            // 相册里有、快照里没有 → 新增。
            changedIDs.insert(record.localIdentifier)
        }

        if !changedIDs.isEmpty {
            // 只让受影响部分失效：登记欠账 + 清相关特征与裁决，
            // 保留其余组与候选，避免用户每加一张照片就等整轮重扫。
            markPendingAnalysisOnQueue(
                records: current.filter { changedIDs.contains($0.localIdentifier) },
                removedIDs: Array(removedIDs)
            )
            guard database.removeFeatureprints(assetIds: Array(changedIDs)),
                  database.clearAutomaticDeleteDecisions(assetIds: Array(changedIDs)) else {
                setPersistenceErrorOnQueue("增量恢复的旧分析结果清理失败，请检查存储空间后重试")
                pauseForPersistenceFailureOnQueue()
                return
            }
        }

        fetchedRecords = current
        let validAssetVersions = assetVersionsOnQueue()
        hashByID = database.allFeatureprintHashes(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: validAssetVersions
        )
        embeddingByID = database.allFeatureprintEmbeddings(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: validAssetVersions
        )
        scoresByID = database.allFeatureprintScores(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: validAssetVersions
        )
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
            // 只要组内有一个成员进了待分析欠账，这条组的相似/替代关系
            // 就已经不可信（它可能正是被删掉的那张的替代品），整组退出结果。
            guard !group.members.contains(where: {
                changedIDs.contains($0.record.localIdentifier)
            }) else { return nil }
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
                  !protectedIDs.contains(candidate.record.localIdentifier),
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
                  !protectedIDs.contains(candidate.record.localIdentifier),
                  !candidate.record.favorite, !candidate.record.isEdited else { return nil }
            return LargeMediaCandidate(
                record: candidate.record,
                estimatedBytes: max(0, candidate.estimatedBytes),
                isOnlyInGroup: true
            )
        }
        snapshotLock.lock()
        // 恢复时同时按两个条件过滤：资产仍在相册里，且**不在待分析欠账里**。
        // 欠账资产的特征已被清掉，若保留它所在的组，用户会看到一套
        // 基于旧特征的相似关系/替代关系，删除建议就失去了依据。
        candidateGroupsSnapshot = restoredCandidates.filter { group in
            group.members.allSatisfy {
                currentIDs.contains($0.localIdentifier)
                    && !changedIDs.contains($0.localIdentifier)
            }
        }
        scoredGroupsSnapshot = filteredScored
        lowQualitySnapshot = safeLowQuality.filter {
            !changedIDs.contains($0.record.localIdentifier)
        }
        largeMediaSnapshot = safeLargeMedia.filter {
            !changedIDs.contains($0.record.localIdentifier)
        }
        snapshotLock.unlock()
        // 结果体与欠账一起落盘：这一步失败也不能让内存视图领先于持久化状态，
        // 所以下面的失败分支会退回"待更新"而不是静默宣称完成。
        if !persistSnapshotsOnQueue() {
            // 保留已恢复的内存结果供浏览，但欠账已落盘（persistSnapshots
            // 内部的 complete 判定会写 0），用户看到的是"结果待更新"。
            notifyResultsChanged()
            return
        }
        notifyResultsChanged()
    }

    /// 全量重建：快照格式不兼容、损坏，或安全数据不可信时的兜底路径。
    /// 这是唯一会清空全部缓存结果的分支；差量场景不走这里。
    private func fullRebuildOnQueue() {
        clearRunSnapshots()
        pendingAnalysis = [:]
        syncPendingAnalysisSnapshotOnQueue()
        if !machine.reset(), let error = machine.lastPersistenceError {
            setPersistenceErrorOnQueue(error)
        }
        publishSnapshot()
        notifyResultsChanged()
    }

    /// 保存完成结果，键值存储只保存 JSON，不复制图像数据。
    @discardableResult
    private func persistSnapshotsOnQueue() -> Bool {
        let encoder = JSONEncoder()
        snapshotLock.lock()
        let candidates = candidateGroupsSnapshot
        let scored = scoredGroupsSnapshot
        let lowQuality = lowQualitySnapshot
        let largeMedia = largeMediaSnapshot
        let assets = fetchedRecords.map(PersistedAssetRecord.init)
        // 只有在状态机到达 done **且**没有任何待分析欠账时才算完整结果。
        // 只要还有新增/修改/删除未被重新分析，就必须写 0，
        // 否则重启恢复会把一套已知不完整的结果当成全库已扫描。
        let complete = (machine.phase == .done && pendingAnalysis.isEmpty) ? "1" : "0"
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
              let largeMediaText = String(data: largeMediaData, encoding: .utf8) else {
            setPersistenceErrorOnQueue("扫描结果序列化失败")
            return false
        }

        let snapshotValues: [String: String?] = [
            SnapshotKeys.schema: String(Self.snapshotSchemaVersion),
            SnapshotKeys.version: String(ScanStateMachine.featureVersion),
            SnapshotKeys.round: snapshotRoundOnQueue(),
            SnapshotKeys.complete: complete,
            SnapshotKeys.assets: assetsText,
            SnapshotKeys.candidates: candidatesText,
            SnapshotKeys.scored: scoredText,
            SnapshotKeys.lowQuality: lowQualityText,
            SnapshotKeys.largeMedia: largeMediaText,
            SnapshotKeys.pending: encodePendingAnalysisOnQueue(),
        ]
        let saved = store.setStringsAtomically(snapshotValues)
        guard saved else {
            setPersistenceErrorOnQueue("扫描结果保存失败，请检查存储空间后重试")
            return false
        }
        // 只有"待分析欠账为空 + 结果已完整保存"才提交完成标记。
        // 顺序很关键：上面的原子写已经带上 complete 值，这里再同步镜像，
        // 保证 UI 看到的 hasPendingAnalysis 与落盘内容一致。
        syncPendingAnalysisSnapshotOnQueue()
        clearPersistenceErrorOnQueue()
        notifyResultsChanged()
        return true
    }

    /// 保存 fetching 完成时的完整资产元数据。候选结果尚未生成时也要保留这份
    /// 基准，以便杀进程恢复时判断旧特征是否仍对应当前相册内容。
    @discardableResult
    private func persistAssetSnapshotOnQueue() -> Bool {
        let encoder = JSONEncoder()
        snapshotLock.lock()
        let assets = fetchedRecords.map(PersistedAssetRecord.init)
        snapshotLock.unlock()
        guard let data = try? encoder.encode(assets),
              let text = String(data: data, encoding: .utf8) else {
            setPersistenceErrorOnQueue("资产快照序列化失败")
            return false
        }
        let snapshotValues: [String: String?] = [
            SnapshotKeys.schema: String(Self.snapshotSchemaVersion),
            SnapshotKeys.version: String(ScanStateMachine.featureVersion),
            SnapshotKeys.round: snapshotRoundOnQueue(),
            SnapshotKeys.complete: "0",
            SnapshotKeys.assets: text,
        ]
        let saved = store.setStringsAtomically(snapshotValues)
        guard saved else {
            setPersistenceErrorOnQueue("资产快照保存失败，请检查存储空间后重试")
            return false
        }
        clearPersistenceErrorOnQueue()
        return true
    }

    private func storedAssetSnapshotOnQueue() -> [PersistedAssetRecord]? {
        guard let version = store.string(forKey: SnapshotKeys.version),
              Int(version) == ScanStateMachine.featureVersion,
              let text = store.string(forKey: SnapshotKeys.assets),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([PersistedAssetRecord].self, from: data)
    }

    private func assetSnapshotsMatch(_ lhs: [PersistedAssetRecord], _ rhs: [PersistedAssetRecord]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let leftByID = Dictionary(lhs.map { ($0.localIdentifier, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let rightByID = Dictionary(rhs.map { ($0.localIdentifier, $0) },
                                   uniquingKeysWith: { first, _ in first })
        return leftByID == rightByID
    }

    private func clearPersistedSnapshotsOnQueue() {
        let emptySnapshot: [String: String?] = [
            SnapshotKeys.schema: nil,
            SnapshotKeys.version: nil,
            SnapshotKeys.round: nil,
            SnapshotKeys.complete: nil,
            SnapshotKeys.assets: nil,
            SnapshotKeys.candidates: nil,
            SnapshotKeys.scored: nil,
            SnapshotKeys.lowQuality: nil,
            SnapshotKeys.largeMedia: nil,
            SnapshotKeys.pending: nil,
        ]
        guard store.setStringsAtomically(emptySnapshot) else {
            setPersistenceErrorOnQueue("旧扫描结果清理失败，请检查存储空间后重试")
            return
        }
        pendingAnalysis = [:]
        syncPendingAnalysisSnapshotOnQueue()
        clearPersistenceErrorOnQueue()
    }

    // MARK: 待分析欠账（增量分析语义）

    /// 待分析集合落盘格式：`[{"id": "...", "version": <时间戳或 null>}]`。
    /// 用数组而非字典，保证相同集合的序列化字节稳定（便于比较与调试）。
    private struct PendingAnalysisEntry: Codable, Equatable {
        let id: String
        let version: Date?
    }

    private func encodePendingAnalysisOnQueue() -> String? {
        let entries = pendingAnalysis
            .map { PendingAnalysisEntry(id: $0.key, version: $0.value) }
            .sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodePendingAnalysis(_ text: String?) -> [String: Date?] {
        guard let text, let data = text.data(using: .utf8),
              let entries = try? JSONDecoder().decode([PendingAnalysisEntry].self, from: data) else {
            return [:]
        }
        var result: [String: Date?] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            result[entry.id] = entry.version
        }
        return result
    }

    private func syncPendingAnalysisSnapshotOnQueue() {
        snapshotLock.lock()
        pendingAnalysisSnapshot = pendingAnalysis
        snapshotLock.unlock()
    }

    /// 登记一批待分析资产（相册新增/修改/删除）。
    ///
    /// - `records`：新增或被修改后的最新元数据，按指定版本入账；
    /// - `removedIDs`：已从相册消失的资产 id，版本记 nil（只表示"要重算"）。
    ///
    /// 已存在同一 id 时**取更新后的版本**：多次变更叠加时以最后一次为准。
    private func markPendingAnalysisOnQueue(
        records: [AssetRecord],
        removedIDs: [String]
    ) {
        for record in records {
            pendingAnalysis[record.localIdentifier] = record.modificationDate
        }
        for id in removedIDs where pendingAnalysis[id] == nil {
            pendingAnalysis[id] = Date?.none
        }
    }

    /// 清掉已经重新分析完成的欠账。只删除版本与当前相册一致的项——
    /// 若资产在这之间又被改过，欠账必须保留，否则会出现"声明已更新但结果仍旧"。
    private func clearPendingAnalysisIfSatisfiedOnQueue(using records: [AssetRecord]) {
        guard !pendingAnalysis.isEmpty else { return }
        let currentByID = Dictionary(
            records.map { ($0.localIdentifier, $0.modificationDate) },
            uniquingKeysWith: { first, _ in first }
        )
        var resolved = Set<String>()
        for (id, version) in pendingAnalysis {
            guard let currentVersion = currentByID[id] else {
                // 资产彻底消失且已经不在当前快照里 → 欠账视为完成。
                resolved.insert(id)
                continue
            }
            if currentVersion == version {
                resolved.insert(id)
            }
        }
        guard !resolved.isEmpty else { return }
        for id in resolved {
            pendingAnalysis[id] = nil
        }
    }

    /// 判断某个 id 是否仍在待分析欠账里（供增量重算范围判定）。
    private func isPendingAnalysisOnQueue(_ id: String) -> Bool {
        pendingAnalysis[id] != nil
    }

    private func snapshotRoundOnQueue() -> String {
        store.string(forKey: SnapshotKeys.round) ?? "0"
    }

    private func beginNewSnapshotRoundOnQueue() {
        let previous = Int(store.string(forKey: SnapshotKeys.round) ?? "0") ?? 0
        let next = String(previous &+ 1)
        let roundValues: [String: String?] = [
            SnapshotKeys.round: next,
            SnapshotKeys.complete: "0",
        ]
        guard store.setStringsAtomically(roundValues) else {
            setPersistenceErrorOnQueue("扫描轮次保存失败，请检查存储空间后重试")
            return
        }
    }

    private func setPersistenceErrorOnQueue(_ message: String) {
        snapshotLock.lock()
        persistenceErrorSnapshot = message
        snapshotLock.unlock()
    }

    private func clearPersistenceErrorOnQueue() {
        snapshotLock.lock()
        persistenceErrorSnapshot = nil
        snapshotLock.unlock()
    }

    func pause() {
        snapshotLock.lock()
        pauseRequested = true
        snapshotLock.unlock()
    }

    func resume() {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.machine.resume() else {
                if let error = self.machine.lastPersistenceError {
                    self.setPersistenceErrorOnQueue(error)
                }
                return
            }
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
        // 阶段推进写盘失败就不能继续往下跑——否则后面整轮都建立在
        // 一个没有真正保存的阶段上，崩溃恢复会读回旧阶段造成混乱。
        if machine.phase == .idle {
            guard advanceOnQueue() else { return }
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
            let currentPersisted = currentRecords.map(PersistedAssetRecord.init)
            let metadataChanged = savedRecords.map {
                !assetSnapshotsMatch($0, currentPersisted)
            } ?? true

            // 即使没有保存快照（兼容旧版本/手工断点），也要把当前全库同步进
            // assets 表，清理已删除资产及其级联特征，避免恢复后数据库落后。
            guard database.replaceAssetSnapshot(currentRecords, fetchedAt: Date()) else {
                setPersistenceErrorOnQueue("资产索引保存失败，请检查存储空间后重试")
                pauseForPersistenceFailureOnQueue()
                return
            }
            fetchedRecords = currentRecords

            if metadataChanged {
                // 增量销毁而不是无条件全清：只删掉"版本对不上"的那些资产特征。
                // 杀进程续扫时大部分资产往往完全没变，把它们的 hash/embedding/score
                // 也清掉会让用户白等一整轮重算。
                //
                // 没有可比对的旧快照（旧版本升级/手工断点）才退回全清——
                // 此时无法证明任何一条特征仍属于当前相册内容。
                let purgeSucceeded: Bool
                if let savedRecords {
                    let currentByID = Dictionary(
                        currentRecords.map { ($0.localIdentifier, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let staleIDs = savedRecords.compactMap { saved -> String? in
                        guard let now = currentByID[saved.localIdentifier] else {
                            // 已从相册删除：特征必须清掉。
                            return saved.localIdentifier
                        }
                        return saved.matches(now) ? nil : saved.localIdentifier
                    }
                    purgeSucceeded = staleIDs.isEmpty
                        || (database.removeFeatureprints(assetIds: staleIDs)
                            && database.clearAutomaticDeleteDecisions(assetIds: staleIDs))
                } else {
                    purgeSucceeded = database.removeAllFeatureprints()
                        && database.clearAutomaticDeleteDecisions()
                }
                guard purgeSucceeded else {
                    setPersistenceErrorOnQueue("旧分析结果清理失败，请检查存储空间后重试")
                    pauseForPersistenceFailureOnQueue()
                    return
                }
                clearRunSnapshots()
                fetchedRecords = currentRecords
                // 回退是恢复语义的一部分：写盘失败就必须停，不能带着
                // 一个没保存的 hashing 阶段继续算，否则重启后阶段与
                // 已清特征不匹配。
                guard machine.rewind(to: .hashing) else {
                    setPersistenceErrorOnQueue(
                        machine.lastPersistenceError ?? "扫描阶段回退失败，请检查存储空间后重试"
                    )
                    pauseForPersistenceFailureOnQueue()
                    return
                }
            }
            guard persistAssetSnapshotOnQueue() else {
                pauseForPersistenceFailureOnQueue()
                return
            }
        }
        hydrateForResumeOnQueue()
        guard !isDriving, machine.isActive else { return }
        isDriving = true
        scanEpoch += 1
        activeBatchEpoch = scanEpoch
        fetchCursor = 0
        stageCursors = [:]
        stageAssetVersions = [:]
        expiredAssetIDs = []
        // 只执行一个批次；后续批次由 driveUntilInactive 重新入队调度。
        // 收尾（清 progressHandler、处理挂起变更）在 finishDrivingOnQueue 里，
        // 由最后一个批次触发——不能在每次批次后都清，否则回调会被提前抹掉。
        driveUntilInactive()
        finishDrivingIfNeededOnQueue()
    }

    /// 一轮扫描真正结束时收尾：清回调、处理挂起变更。
    /// 仅当状态机不再活动且没有待调度批次时执行。
    /// 在 workQueue 上推进状态机阶段，并把"写盘失败"统一转成可见错误 + 暂停。
    ///
    /// 返回 false 表示**阶段没有真正切换到磁盘**：调用方必须立即停止本轮，
    /// 不得继续调度下一批，也不得向 UI 声明扫描完成。
    private func advanceOnQueue() -> Bool {
        guard machine.advance() else {
            if let error = machine.lastPersistenceError {
                setPersistenceErrorOnQueue(error)
                pauseForPersistenceFailureOnQueue()
            }
            return false
        }
        publishSnapshot()
        reportProgress()
        return true
    }

    /// 在 workQueue 上暂停状态机并回报写盘错误。
    /// 写盘失败会让"暂停前阶段"无法保存，恢复时可能落到 fetching 重扫——
    /// 这比静默继续安全，但要如实报错，不能假装暂停成功。
    @discardableResult
    private func pauseCheckedOnQueue(reason: String) -> Bool {
        let paused = machine.pause(reason: reason)
        if !paused, let error = machine.lastPersistenceError {
            setPersistenceErrorOnQueue(error)
        }
        publishSnapshot()
        reportProgress()
        return paused
    }

    private func finishDrivingIfNeededOnQueue() {
        guard isDriving, !machine.isActive, !isSchedulingNextBatch else { return }
        // 状态机写盘失败时，本轮的阶段切换并没有真正保存下来。
        // 这种情况不能当作扫描完成：向 UI 暴露持久化错误并暂停，
        // 让用户释放空间后重试，而不是让重启后读到一个"半套"状态。
        if let error = machine.lastPersistenceError {
            setPersistenceErrorOnQueue(error)
            pauseForPersistenceFailureOnQueue()
            return
        }
        isDriving = false
        fetchCursor = 0
        // 轮次收官：过期批次的判定基准随之复位。阶段游标与版本表只在
        // 本轮内有效，不清掉会让下一轮从中间位置开始、跳过一批资产。
        activeBatchEpoch = 0
        stageCursors = [:]
        stageAssetVersions = [:]
        expiredAssetIDs = []
        // 本轮真正跑完（done）时结算待分析欠账：只有在这批资产的最新版本
        // 确实被重新分析完成后才销账。版本又变了则欠账保留，下一轮继续。
        if machine.phase == .done {
            let before = pendingAnalysis.count
            clearPendingAnalysisIfSatisfiedOnQueue(using: fetchedRecords)
            if pendingAnalysis.count != before {
                // 销账后结果集才可能变为"完整"，需要重新落盘 complete 标记。
                _ = persistSnapshotsOnQueue()
            }
            syncPendingAnalysisSnapshotOnQueue()
        }
        // 回调只服务当前一轮；清掉闭包，避免 SwiftUI View 被引擎长期持有形成引用链。
        snapshotLock.lock()
        progressHandler = nil
        snapshotLock.unlock()
        if pendingLibraryChange, machine.phase == .done {
            let changed = pendingChangedIDs
            let records = pendingChangedRecords
            pendingLibraryChange = false
            pendingChangedIDs = []
            pendingChangedRecords = []
            // 当前轮次可能是在相册变更前取到的快照。只丢弃涉及变更的
            // 组/候选，保留其余结果，等待下一次增量扫描补齐新资产。
            invalidateViewsForChangedIDsOnQueue(changed, replacementRecords: records)
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

        hashByID = database.allFeatureprintHashes(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: assetVersionsOnQueue()
        )
        let hashGroups = CandidateGrouper.groups(from: fetchedRecords, hashByID: hashByID)
        setCandidateGroupsSnapshot(hashGroups)

        guard machine.phase == .embedding || machine.phase == .clustering || machine.phase == .scoring else {
            return
        }

        embeddingByID = database.allFeatureprintEmbeddings(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: assetVersionsOnQueue()
        )
        guard machine.phase == .clustering || machine.phase == .scoring else { return }

        let claimed = Set(hashGroups.flatMap(\.memberIDs))
        let embeddingPending = fetchedRecords.filter { !claimed.contains($0.localIdentifier) }
        let hasMissingEmbedding = embeddingPending.contains {
            guard let vector = embeddingByID[$0.localIdentifier] else { return true }
            return !EmbeddingMath.isUsable(vector)
        }
        if hasMissingEmbedding {
            if !machine.rewind(to: .embedding), let error = machine.lastPersistenceError {
                setPersistenceErrorOnQueue(error)
                pauseForPersistenceFailureOnQueue()
                return
            }
            setCandidateGroupsSnapshot(hashGroups)
            return
        }

        setCandidateGroupsSnapshot(embeddingGroups(baseGroups: hashGroups))
    }

    /// 阶段内部游标复用：clustering 阶段被分批调用后，这里只做
    /// "embedding 已补齐、候选组已按批累加完成"的一致性收尾。
    /// 真正逐单元组装 embedding 组的工作在 `runClusteringStage()` 里按批执行。
    private func embeddingGroups(baseGroups: [CandidateGroup]) -> [CandidateGroup] {
        let claimed = Set(baseGroups.flatMap(\.memberIDs))
        let pending = fetchedRecords.filter {
            guard !claimed.contains($0.localIdentifier) else { return false }
            guard let vector = embeddingByID[$0.localIdentifier] else { return true }
            return !EmbeddingMath.isUsable(vector)
        }
        guard pending.isEmpty else { return baseGroups }
        // 已全部补齐：保留既有组装结果（clustering 阶段已按批累加）。
        return baseGroups
    }

    /// 逐阶段推进。每次队列轮次只执行**有限个批次**，而不是在一个同步循环里
    /// 跑完整轮（T03/T04 补充验收）。
    ///
    /// 为什么不是"每批都重新入队"：
    /// - 重新入队确实能让暂停/变更通知优先执行，但会让"扫描是否跑完"变成
    ///   一个跨多个队列轮次的异步问题；调用方（含测试）只做一次队列屏障
    ///   就无法确认整轮结束，真机上"扫描完成"也会比预期晚一拍才可见。
    /// - 折中：一轮 `driveUntilInactive()` 连续推进最多
    ///   `maxBatchesPerTurn` 个批次，然后重新入队让出。暂停/失效检查仍在
    ///   **每个**批次边界执行，语义不变；小库（批次总数不多）可以在一轮内
    ///   跑完，大库则每轮让出一次，UI 与变更监听不会被饿死。
    private func driveUntilInactive() {
        for _ in 0..<Self.maxBatchesPerTurn {
            guard scanEpoch == activeBatchEpoch else { return }

            // 批次边界先处理挂起的失效请求：相册变更会让已算出的结果过期，
            // 必须在推进到下一批之前失效，否则过期分析会覆盖新状态。
            if handlePendingInvalidationOnQueue() { return }

            guard machine.isActive else { return }

            let didWork: Bool
            switch machine.phase {
            case .fetching:
                didWork = runFetchingBatch()
            case .hashing:
                didWork = runHashingStage()
            case .embedding:
                didWork = runEmbeddingStage()
            case .clustering:
                didWork = runClusteringStage()
            case .scoring:
                didWork = runScoringStage()
            case .idle, .done, .paused:
                publishSnapshot()
                reportProgress()
                return
            }

            publishSnapshot()
            reportProgress()

            guard didWork, machine.isActive else { return }
        }

        // 这一轮用完了批次额度但阶段还没结束：把下一轮重新排到工作队列尾，
        // 让排队中的暂停请求与其它 async 变更处理先得到执行机会。
        guard machine.isActive else { return }
        scheduleNextBatchOnQueue()
    }

    /// 把下一批重新排到工作队列尾。与直接调用相比，这保证同队列上排队中的
    /// 暂停请求、以及其它 async 提交的变更处理先得到执行机会。
    private func scheduleNextBatchOnQueue() {
        guard !isSchedulingNextBatch else { return }
        isSchedulingNextBatch = true
        let scheduledEpoch = scanEpoch
        workQueue.async { [weak self] in
            guard let self else { return }
            self.isSchedulingNextBatch = false
            guard self.isDriving, self.machine.isActive,
                  self.scanEpoch == scheduledEpoch else {
                // 已被暂停/失效/换轮：本轮到此处为止，走收尾。
                self.finishDrivingIfNeededOnQueue()
                return
            }
            self.driveUntilInactive()
            self.finishDrivingIfNeededOnQueue()
        }
    }

    /// 在批次边界处理相册变更/失效请求。返回 true 表示本轮已中止
    /// （调用方应立即返回，不再调度下一批）。
    private func handlePendingInvalidationOnQueue() -> Bool {
        snapshotLock.lock()
        let hasPending = pendingLibraryChange
        snapshotLock.unlock()
        guard hasPending else { return false }
        // 扫描进行中收到相册变更：当前轮次的部分中间结果已不可信。
        // 先暂停，等下一轮 fetching 重新拉取元数据；不在这里静默继续。
        if machine.isActive {
            pauseCheckedOnQueue(reason: "相册已变更，等待重新扫描")
        }
        publishSnapshot()
        reportProgress()
        return true
    }

    private func pauseOnQueue() {
        pauseCheckedOnQueue(reason: "用户暂停")
    }

    /// fetching：拉全库元数据 → 落盘 → 按批次汇报进度。
    ///
    /// 返回 true 表示本批完成、还有后续批次可调度；返回 false 表示
    /// 整个阶段已完成、或中途被打断（暂停/持久化失败/失效）。
    @discardableResult
    private func runFetchingBatch() -> Bool {
        // 首批：拉全库元数据并清空上一轮中间结果。
        if fetchCursor == 0 {
            let assets = uniqueRecords(
                photoLibrary.fetchAllAssets().filter { !$0.localIdentifier.isEmpty }
            )
            fetchedRecords = assets
            hashByID = [:]
            embeddingByID = [:]
            scoresByID = [:]
        }

        let assets = fetchedRecords
        guard !assets.isEmpty else {
            // 空库：直接推进，不留游标。
            fetchCursor = 0
            completeFetchingStage()
            return true
        }

        // 本轮资产版本基线。后续所有阶段写库前都用它校验资产未被修改，
        // 保证"过期分析结果不能覆盖新状态"。
        stageAssetVersions = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0.modificationDate) }
        )
        expiredAssetIDs = []

        let batchSize = max(1, AppConfig.scanBatchSize)
        let end = min(fetchCursor + batchSize, assets.count)
        for index in fetchCursor..<end {
            if consumePauseRequest() {
                _ = pauseCheckedOnQueue(reason: "用户暂停")
                fetchCursor = index
                return false
            }
            machine.setProgress(Double(index + 1) / Double(max(assets.count, 1)))
        }
        fetchCursor = end
        publishSnapshot()
        reportProgress()

        guard fetchCursor >= assets.count else { return true }
        fetchCursor = 0
        completeFetchingStage()
        return true
    }

    /// fetching 阶段收尾：落盘资产快照 → 保存全量记录 → 推进阶段。
    private func completeFetchingStage() {
        let assets = fetchedRecords
        let fetchedAt = Date()
        if consumePauseRequest() {
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return
        }
        // 全量快照同时负责清理相册外部删除但尚未收到 change observer 事件的旧行。
        guard database.replaceAssetSnapshot(assets, fetchedAt: fetchedAt) else {
            setPersistenceErrorOnQueue("资产索引保存失败，请检查存储空间后重试")
            pauseForPersistenceFailureOnQueue()
            return
        }
        // 先保存全量 AssetRecord，再推进阶段；这样在 hashing/embedding 等
        // 后续阶段被杀时可以比较收藏、编辑、尺寸、时间、地理和 Live Photo 等字段。
        guard persistAssetSnapshotOnQueue() else {
            pauseForPersistenceFailureOnQueue()
            return
        }
        guard advanceOnQueue() else { return }
    }

    /// hashing：逐资产拉缩略图 → 计算 pHash → 落 featureprints 表；
    /// 阶段末用 (时间×地理×pHash) 产出候选组。无注入实现时空转推进（占位语义保留）。
    /// 已持久化的当前版本哈希直接复用（杀进程续扫不重算）。
    ///
    /// 每次调用只处理 [`AppConfig.scanBatchSize`] 张资产：本阶段的**内层**
    /// 工作量与外围循环一样有上界，暂停/变更通知在批次边界即可生效。
    private func runHashingStage() -> Bool {
        let phase = ScanPhase.hashing
        let total = max(fetchedRecords.count, 1)

        // 首批：载入已持久化的、当前版本仍然有效的哈希。
        if cursorOnQueue(for: phase) == 0 {
            hashByID = [:]
            for (assetId, hash) in database.allFeatureprintHashes(
                featureVersion: ScanStateMachine.featureVersion,
                validAssetVersions: assetVersionsOnQueue()
            ) {
                hashByID[assetId] = hash
            }
        }

        let start = min(cursorOnQueue(for: phase), fetchedRecords.count)
        let end = min(start + max(1, AppConfig.scanBatchSize), fetchedRecords.count)
        var pendingWrites: [FeatureprintWrite] = []

        // 本批先做一次资产版本校验：过期资产不参与计算，也不写库。
        for index in currentVersionIndicesOnQueue(fetchedRecords, range: start..<end) {
            let record = fetchedRecords[index]
            if hashByID[record.localIdentifier] == nil,
               let data = imageDataOnQueue(record.localIdentifier),
               let hash = hashComputer(data) {
                hashByID[record.localIdentifier] = hash
                pendingWrites.append(FeatureprintWrite(
                    assetId: record.localIdentifier,
                    data: FeaturePrintCodec.encodeHash(hash),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date(),
                    assetVersion: record.modificationDate
                ))
            }
            if pendingWrites.count >= AppConfig.scanBatchSize {
                guard flushFeatureprintWritesOnQueue(
                    &pendingWrites,
                    failureMessage: "特征保存失败，请检查存储空间后重试"
                ) else {
                    pauseForPersistenceFailureOnQueue()
                    return false
                }
            }
            throttleForThermalPressure()
        }

        guard flushFeatureprintWritesOnQueue(
            &pendingWrites,
            failureMessage: "特征保存失败，请检查存储空间后重试"
        ) else {
            pauseForPersistenceFailureOnQueue()
            return false
        }

        if consumePauseRequest() {
            setCursorOnQueue(start, for: phase)
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return false
        }

        machine.setProgress(Double(end) / Double(total))
        publishSnapshot()
        reportProgress()

        guard end >= fetchedRecords.count else {
            setCursorOnQueue(end, for: phase)
            // 返回 true：还有后续批次可调度。
            return true
        }

        // 本阶段最后一批：组装候选组、推进阶段、清游标。
        clearCursorOnQueue(for: phase)
        let groups = CandidateGrouper.groups(from: fetchedRecords, hashByID: hashByID)
        setCandidateGroupsSnapshot(groups)

        return advanceOnQueue()
    }

    /// embedding：对未被 pHash 组认领的资产计算特征向量（L2 归一化）→ 落表。
    /// 已持久化的当前版本向量直接复用。无注入实现时空转推进。
    /// 与 hashing 一样按批次切分内层工作。
    private func runEmbeddingStage() -> Bool {
        let phase = ScanPhase.embedding

        // 待处理集合在阶段内是稳定的：只依赖候选组与 fetchedRecords，
        // 不随游标变化，所以每批重算即可，不必额外持久化。
        let claimed = Set(candidateGroupsOnQueue().flatMap(\.memberIDs))
        let pending = fetchedRecords.filter {
            !claimed.contains($0.localIdentifier) && !expiredAssetIDs.contains($0.localIdentifier)
        }
        let total = max(pending.count, 1)

        if cursorOnQueue(for: phase) == 0 {
            embeddingByID = [:]
            for (assetId, vector) in database.allFeatureprintEmbeddings(
                featureVersion: ScanStateMachine.featureVersion,
                validAssetVersions: assetVersionsOnQueue()
            ) {
                embeddingByID[assetId] = vector
            }
        }

        let start = min(cursorOnQueue(for: phase), pending.count)
        let end = min(start + max(1, AppConfig.scanBatchSize), pending.count)
        var pendingWrites: [FeatureprintWrite] = []

        for index in currentVersionIndicesOnQueue(pending, range: start..<end) {
            let record = pending[index]
            if embeddingByID[record.localIdentifier] == nil,
               let data = imageDataOnQueue(record.localIdentifier),
               let rawVector = embeddingComputer(data) {
                let vector = EmbeddingMath.normalized(rawVector)
                if EmbeddingMath.isUsable(vector) {
                    embeddingByID[record.localIdentifier] = vector
                    pendingWrites.append(FeatureprintWrite(
                        assetId: record.localIdentifier,
                        data: FeaturePrintCodec.encodeEmbedding(vector),
                        featureVersion: ScanStateMachine.featureVersion,
                        computedAt: Date(),
                        assetVersion: record.modificationDate
                    ))
                }
            }
            if pendingWrites.count >= AppConfig.scanBatchSize {
                guard flushFeatureprintWritesOnQueue(
                    &pendingWrites,
                    failureMessage: "特征保存失败，请检查存储空间后重试"
                ) else {
                    pauseForPersistenceFailureOnQueue()
                    return false
                }
            }
            throttleForThermalPressure()
        }

        guard flushFeatureprintWritesOnQueue(
            &pendingWrites,
            failureMessage: "特征保存失败，请检查存储空间后重试"
        ) else {
            pauseForPersistenceFailureOnQueue()
            return false
        }

        if consumePauseRequest() {
            setCursorOnQueue(start, for: phase)
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return false
        }

        machine.setProgress(Double(end) / Double(total))
        publishSnapshot()
        reportProgress()

        guard end >= pending.count else {
            setCursorOnQueue(end, for: phase)
            return true
        }

        clearCursorOnQueue(for: phase)
        return advanceOnQueue()
    }

    /// clustering：在 (时间桶 × 地理单元) 内对 embedding 做阈值连通分量，
    /// ≥2 成员的分量并入候选组（pHash 已认领的资产不重复进组）。确定性输出。
    ///
    /// 连通分量本身是单元内的一次计算，无法在单元中间安全切分；因此按
    /// **时间×地理单元**分批，每批处理 [`AppConfig.scanBatchSize`] 个单元。
    private func runClusteringStage() -> Bool {
        let phase = ScanPhase.clustering
        let units = CandidateGrouper.timeGeoUnits(from: fetchedRecords)
        let total = max(units.count, 1)

        // 首批：以 pHash 候选组为基线，并把游标清零。
        if cursorOnQueue(for: phase) == 0 {
            setCandidateGroupsSnapshot(candidateGroupsOnQueue())
        }

        let start = min(cursorOnQueue(for: phase), units.count)
        let end = min(start + max(1, AppConfig.scanBatchSize), units.count)

        // 累加式组装：每批在已有的候选组上追加本批的 embedding 连通分量。
        // 与一次性全量重算等价（后批看到的 claimed 集合更大），且每批有界。
        var groups = candidateGroupsOnQueue()
        for unit in units[start..<end] {
            let claimed = Set(groups.flatMap(\.memberIDs))
            let members = unit.members.filter {
                guard !claimed.contains($0.localIdentifier),
                      !expiredAssetIDs.contains($0.localIdentifier),
                      let vector = embeddingByID[$0.localIdentifier] else { return false }
                return EmbeddingMath.isUsable(vector)
            }
            guard members.count >= 2 else { continue }

            let vectors = members.compactMap { member -> (id: String, vector: [Double])? in
                guard let vector = embeddingByID[member.localIdentifier],
                      EmbeddingMath.isUsable(vector) else { return nil }
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
        setCandidateGroupsSnapshot(groups)

        if consumePauseRequest() {
            setCursorOnQueue(start, for: phase)
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return false
        }

        machine.setProgress(Double(end) / Double(total))
        publishSnapshot()
        reportProgress()

        guard end >= units.count else {
            setCursorOnQueue(end, for: phase)
            return true
        }

        clearCursorOnQueue(for: phase)
        return advanceOnQueue()
    }

    /// scoring：逐组跑 GroupScoring（KeepScore 接线 + 冗余度 + SafetyRules 过滤）
    /// → Best Shot 标记 → 预删除候选集。缺特征的资产按中性值参与评分。
    ///
    /// 本阶段每批只评 [`AppConfig.scanBatchSize`] 个组。组间互不依赖，
    /// 已评组累加进快照；标签保留在阶段末的检测 pass 里执行（它们需要
    /// 完整候选组集合，且各自也按批次推进）。
    private func runScoringStage() -> Bool {
        let phase = ScanPhase.scoring
        guard let protectedIDs = keepDecisionIDsOnQueue() else {
            pauseForSafetyFailureOnQueue()
            return false
        }
        keepDecisionIDsForRun = protectedIDs

        // 首批：载入已持久化分数，并清空上一轮评分快照。
        if cursorOnQueue(for: phase) == 0 {
            setScoredGroupsSnapshot([])
            for (assetId, values) in database.allFeatureprintScores(
                featureVersion: ScanStateMachine.featureVersion,
                validAssetVersions: assetVersionsOnQueue()
            )
            where values.count == 4 {
                scoresByID[assetId] = VisionResultAggregator.aggregate(
                    clarity: values[0], aesthetics: values[1],
                    faceQuality: values[2], saliency: values[3]
                )
            }
        }

        let groups = candidateGroupsOnQueue()
        let total = max(groups.count, 1)
        let start = min(cursorOnQueue(for: phase), groups.count)
        let end = min(start + max(1, AppConfig.scanBatchSize), groups.count)
        var scored = scoredGroupsOnQueue()

        for index in start..<end {
            let group = groups[index]
            // 组内成员版本校验：成员在批次之间被修改过就不能按旧特征评分，
            // 该组整体留待下一轮重算，避免过期分析落库。
            if group.members.contains(where: { !assetVersionIsCurrentOnQueue($0) }) {
                continue
            }

            // 缺分数的成员补算（经注入的分析器；失败回退中性值由聚合层保证）。
            for member in group.members where scoresByID[member.localIdentifier] == nil {
                guard let data = imageDataOnQueue(member.localIdentifier),
                      let features = featureAnalyzer(data) else { continue }
                let sanitized = VisionResultAggregator.aggregate(
                    clarity: features.clarity,
                    aesthetics: features.aesthetics,
                    faceQuality: features.faceQuality,
                    saliency: features.saliency
                )
                scoresByID[member.localIdentifier] = sanitized
                guard database.upsertFeatureprint(
                    assetId: member.localIdentifier,
                    data: FeaturePrintCodec.encodeScores([
                        sanitized.clarity, sanitized.aesthetics,
                        sanitized.faceQuality, sanitized.saliency,
                    ]),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date(),
                    assetVersion: member.modificationDate
                ) else {
                    setPersistenceErrorOnQueue("评分保存失败，请检查存储空间后重试")
                    pauseForPersistenceFailureOnQueue()
                    return false
                }
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
        }
        setScoredGroupsSnapshot(scored)

        if consumePauseRequest() {
            setCursorOnQueue(start, for: phase)
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return false
        }

        machine.setProgress(Double(end) / Double(total))
        publishSnapshot()
        reportProgress()

        guard end >= groups.count else {
            setCursorOnQueue(end, for: phase)
            return true
        }

        clearCursorOnQueue(for: phase)
        guard detectLowQuality() else { return false }
        guard detectLargeMedia() else { return false }
        guard persistSnapshotsOnQueue() else {
            pauseForPersistenceFailureOnQueue()
            return false
        }

        // 阶段切换与最终结果必须在同一轮内都成功：状态机落盘失败时
        // 不能声明扫描完成，否则重启后会读到"done 但结果快照是上一轮的"
        // 这种不一致状态。
        guard advanceOnQueue() else { return false }
        // 结果集完整标记（complete=1）在进入 done 之后才写，
        // 避免恢复流程接受一个在最终阶段切换前拍下的快照。
        guard persistSnapshotsOnQueue() else {
            pauseForPersistenceFailureOnQueue()
            return false
        }
        return true
    }

    /// 低质量检测 pass（T16）：未被相似组认领的 image 资产，clarity 阈值 +
    /// 曝光直方图三分支判定；EXIF 夜间白名单命中只打豁免标（红线 6：永不进
    /// 预选集合，不落删除裁决）。裁决幂等：已有用户 keep（user_override）的
    /// 资产不再自动改写。
    /// 成本注记：每个未认领资产多一次缩略图读取（曝光探测）；V1 先正确后省，
    /// 大库优化属后续迭代（可与 hashing 阶段合并采样）。
    private func detectLowQuality() -> Bool {
        let phase = ScanPhase.scoring
        let claimed = Set(candidateGroupsOnQueue().flatMap(\.memberIDs))
        guard let protectedIDs = keepDecisionIDsForRun else {
            pauseForSafetyFailureOnQueue()
            return false
        }

        let total = max(fetchedRecords.count, 1)
        let start = min(cursorOnQueue(for: Self.lowQualityPassKey), fetchedRecords.count)
        let end = min(start + max(1, AppConfig.scanBatchSize), fetchedRecords.count)
        var detected = start == 0 ? [] : lowQualitySnapshotOnQueue()

        for index in start..<end {
            let record = fetchedRecords[index]
            guard !claimed.contains(record.localIdentifier),
                  record.mediaType == .image,
                  !record.favorite, !record.isEdited else { continue }
            // 版本校验：批次之间被修改过的资产不落旧裁决。
            guard assetVersionIsCurrentOnQueue(record) else { continue }

            let assetId = record.localIdentifier
            // 用户明确保留/移出候选的资产在后续重扫中也不应被自动加回。
            guard !protectedIDs.contains(assetId) else { continue }
            let imageData = imageDataOnQueue(assetId)

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
                guard database.upsertFeatureprint(
                    assetId: assetId,
                    data: FeaturePrintCodec.encodeScores([
                        sanitized.clarity, sanitized.aesthetics,
                        sanitized.faceQuality, sanitized.saliency,
                    ]),
                    featureVersion: ScanStateMachine.featureVersion,
                    computedAt: Date(),
                    assetVersion: record.modificationDate
                ) else {
                    setPersistenceErrorOnQueue("评分保存失败，请检查存储空间后重试")
                    pauseForPersistenceFailureOnQueue()
                    return false
                }
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
                guard database.setDecision(
                    assetId: assetId,
                    verdict: .delete,
                    reason: "low_quality:\(kind.rawValue)",
                    decidedAt: Date()
                ) else {
                    setPersistenceErrorOnQueue("低质量裁决保存失败，请检查存储空间后重试")
                    pauseForPersistenceFailureOnQueue()
                    return false
                }
            }
            throttleForThermalPressure()
        }

        snapshotLock.lock()
        lowQualitySnapshot = detected
        snapshotLock.unlock()

        if consumePauseRequest() {
            setCursorOnQueue(start, for: Self.lowQualityPassKey)
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return false
        }
        machine.setProgress(Double(end) / Double(total))
        publishSnapshot()
        reportProgress()

        guard end >= fetchedRecords.count else {
            setCursorOnQueue(end, for: Self.lowQualityPassKey)
            return false  // 检测 pass 未跑完，本批次到此为止
        }
        clearCursorOnQueue(for: Self.lowQualityPassKey)
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

        let total = max(safeCandidates.count, 1)
        let start = min(cursorOnQueue(for: Self.largeMediaPassKey), safeCandidates.count)
        let end = min(start + max(1, AppConfig.scanBatchSize), safeCandidates.count)
        // 累加进快照：每一批的检测结果都要保留，否则多批之后只剩最后一批。
        var detected = start == 0 ? [] : largeMediaSnapshotOnQueue()

        for index in start..<end {
            let candidate = safeCandidates[index]
            // 只有**确认**本机可用的资产才制造自动删除裁决。iCloud 未下载
            // 与状态未知都只做信息展示：前者用户无法立即执行，后者探测尚未
            // 得出结论，都不应生成一个无法执行的待确认删除项。
            // 注意：候选仍进快照（用户看不到不等于该资产不存在），只是不落裁决。
            detected.append(candidate)
            guard candidate.record.localAvailability == .available,
                  assetVersionIsCurrentOnQueue(candidate.record) else { continue }
            let assetId = candidate.record.localIdentifier
            if candidate.canPreselect {
                guard database.setDecision(
                    assetId: assetId,
                    verdict: .delete,
                    reason: "large_media",
                    decidedAt: Date()
                ) else {
                    setPersistenceErrorOnQueue("大媒体裁决保存失败，请检查存储空间后重试")
                    pauseForPersistenceFailureOnQueue()
                    return false
                }
            }
            throttleForThermalPressure()
        }

        snapshotLock.lock()
        largeMediaSnapshot = detected
        snapshotLock.unlock()

        if consumePauseRequest() {
            setCursorOnQueue(start, for: Self.largeMediaPassKey)
            _ = pauseCheckedOnQueue(reason: "用户暂停")
            return false
        }
        machine.setProgress(Double(end) / Double(total))
        publishSnapshot()
        reportProgress()

        guard end >= safeCandidates.count else {
            setCursorOnQueue(end, for: Self.largeMediaPassKey)
            return false  // 检测 pass 未跑完，本批次到此为止
        }
        clearCursorOnQueue(for: Self.largeMediaPassKey)
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

    /// 批次边界钩子。曾经用 Thread.sleep 模拟"让出队列"，现已移除：
    /// 真正的让出由 `scheduleNextBatchOnQueue()` 把下一批重新入队实现，
    /// 队列上排队中的暂停/变更通知因此能先执行。这里保留空实现只为
    /// 兼容既有调用点，新增代码不应再依赖它。
    private func yieldAfterBatchIfNeeded(index: Int) {
        _ = index
    }

    private func imageDataOnQueue(_ assetID: String) -> Data? {
        guard !assetID.isEmpty else { return nil }
        if let cached = imageDataCache[assetID] {
            imageDataCacheOrder.removeAll { $0 == assetID }
            imageDataCacheOrder.append(assetID)
            return cached
        }
        guard let data = imageDataLoader(assetID) else { return nil }
        guard data.count <= maxImageDataCacheBytes else { return data }
        while imageDataCacheBytes + data.count > maxImageDataCacheBytes,
              let evictedID = imageDataCacheOrder.first {
            imageDataCacheOrder.removeFirst()
            if let evicted = imageDataCache.removeValue(forKey: evictedID) {
                imageDataCacheBytes -= evicted.count
            }
        }
        imageDataCache[assetID] = data
        imageDataCacheOrder.append(assetID)
        imageDataCacheBytes += data.count
        return data
    }

    private func removeCachedImageOnQueue(_ assetID: String) {
        guard let removed = imageDataCache.removeValue(forKey: assetID) else { return }
        imageDataCacheBytes = max(0, imageDataCacheBytes - removed.count)
        imageDataCacheOrder.removeAll { $0 == assetID }
    }

    private func flushFeatureprintWritesOnQueue(
        _ writes: inout [FeatureprintWrite],
        failureMessage: String
    ) -> Bool {
        guard !writes.isEmpty else { return true }
        let success = database.upsertFeatureprints(writes)
        writes.removeAll(keepingCapacity: true)
        if !success {
            setPersistenceErrorOnQueue(failureMessage)
        }
        return success
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

    // MARK: 阶段边界：游标与版本校验

    /// 读取某个阶段的内部游标（已处理条数）。
    ///
    /// `stageKey` 把 `ScanPhase` 和 scoring 阶段里的两个检测 pass
    /// （`lowQualityPass` / `largeMediaPass`）统一成一个键空间。
    private func stageKey(_ phase: ScanPhase) -> String {
        switch phase {
        case .fetching: return "fetching"
        case .hashing: return "hashing"
        case .embedding: return "embedding"
        case .clustering: return "clustering"
        case .scoring: return "scoring"
        case .idle, .done, .paused: return "inactive"
        }
    }

    /// scoring 阶段内部的低质量检测 pass 游标键（非 ScanPhase 成员）。
    private static let lowQualityPassKey = "scoring.lowQuality"
    /// scoring 阶段内部的大媒体检测 pass 游标键（非 ScanPhase 成员）。
    private static let largeMediaPassKey = "scoring.largeMedia"

    private func cursorOnQueue(for phase: ScanPhase) -> Int {
        stageCursors[stageKey(phase)] ?? 0
    }

    private func cursorOnQueue(for key: String) -> Int {
        stageCursors[key] ?? 0
    }

    /// 写回某个阶段的内部游标。0 视为"无游标"，直接删除键。
    private func setCursorOnQueue(_ value: Int, for phase: ScanPhase) {
        setCursorOnQueue(value, for: stageKey(phase))
    }

    private func setCursorOnQueue(_ value: Int, for key: String) {
        if value <= 0 {
            stageCursors[key] = nil
        } else {
            stageCursors[key] = value
        }
    }

    /// 阶段完成后清掉自己的游标，避免残留值影响下次进入同一阶段。
    private func clearCursorOnQueue(for phase: ScanPhase) {
        stageCursors[stageKey(phase)] = nil
    }

    private func clearCursorOnQueue(for key: String) {
        stageCursors[key] = nil
    }

    /// 资产内容版本校验：当前相册里的这张资产是否仍与扫描开始时一致。
    ///
    /// 批次之间用户可能编辑/替换了资产。若仍按旧版本写特征，新状态会被
    /// 过期分析结果覆盖——这正是"过期分析结果不能覆盖新状态"要挡的情况。
    /// 校验失败时把 id 记入 `expiredAssetIDs` 并在本批放弃处理，等下一轮
    /// fetching 重新取元数据后重算。
    private func assetVersionIsCurrentOnQueue(_ record: AssetRecord) -> Bool {
        let id = record.localIdentifier
        if expiredAssetIDs.contains(id) { return false }
        guard let baseline = stageAssetVersions[id] else {
            // 基线里没有这张资产：本批新出现（相册变更），版本无从比较。
            expiredAssetIDs.insert(id)
            return false
        }
        guard baseline == record.modificationDate else {
            expiredAssetIDs.insert(id)
            removeCachedImageOnQueue(id)
            return false
        }
        return true
    }

    /// 批量版本校验结果：返回本批中版本仍然有效的下标（顺序保持）。
    private func currentVersionIndicesOnQueue(
        _ records: [AssetRecord],
        range: Range<Int>
    ) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(range.count)
        for index in range where assetVersionIsCurrentOnQueue(records[index]) {
            result.append(index)
        }
        return result
    }

    /// 当前轮次的资产内容版本。Dictionary 的 value 保留 Optional，
    /// 使数据库能区分“确认没有修改时间”和“根本没有这张资产”。
    private func assetVersionsOnQueue() -> [String: Date?] {
        Dictionary(
            uniqueKeysWithValues: fetchedRecords.map {
                ($0.localIdentifier, $0.modificationDate)
            }
        )
    }

    /// 相册局部变更只使相关组/候选失效。无关结果继续可见，避免用户每删
    /// 一批照片就被迫重新等待整轮扫描；受影响资产的特征已在调用方先清掉。
    private func invalidateViewsForChangedIDsOnQueue(
        _ changedIDs: Set<String>,
        replacementRecords: [AssetRecord]
    ) {
        guard !changedIDs.isEmpty else { return }
        fetchedRecords.removeAll { changedIDs.contains($0.localIdentifier) }
        let existingIDs = Set(fetchedRecords.map(\.localIdentifier))
        for record in uniqueRecords(replacementRecords)
        where !existingIDs.contains(record.localIdentifier) {
            fetchedRecords.append(record)
        }
        for id in changedIDs {
            hashByID[id] = nil
            embeddingByID[id] = nil
            scoresByID[id] = nil
            removeCachedImageOnQueue(id)
        }

        snapshotLock.lock()
        candidateGroupsSnapshot.removeAll { group in
            group.memberIDs.contains { changedIDs.contains($0) }
        }
        scoredGroupsSnapshot.removeAll { group in
            group.members.contains {
                changedIDs.contains($0.record.localIdentifier)
            }
        }
        lowQualitySnapshot.removeAll {
            changedIDs.contains($0.record.localIdentifier)
        }
        largeMediaSnapshot.removeAll {
            changedIDs.contains($0.record.localIdentifier)
        }
        snapshotLock.unlock()
        // 变更后的结果集不再是"完整"状态：待分析欠账已在调用方登记，
        // 这里一并落盘，保证重启后仍能差量恢复而不是误判为已扫描完成。
        _ = persistSnapshotsOnQueue()
    }

    private func scoredGroupsOnQueue() -> [ScoredGroup] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return scoredGroupsSnapshot
    }

    /// 检测 pass 分批累加时读取已有结果，避免多批之后只剩最后一批。
    private func lowQualitySnapshotOnQueue() -> [LowQualityCandidate] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return lowQualitySnapshot
    }

    private func largeMediaSnapshotOnQueue() -> [LargeMediaCandidate] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return largeMediaSnapshot
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
