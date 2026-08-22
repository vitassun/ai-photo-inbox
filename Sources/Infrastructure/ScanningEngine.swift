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

    /// fetching 阶段捕获的当轮快照与哈希结果（仅 workQueue 上读写）。
    private var fetchedRecords: [AssetRecord] = []
    private var hashByID: [String: String] = [:]

    /// 候选组产出（T05 精比 / T09 评分消费）。镜像受 snapshotLock 保护。
    private var candidateGroupsSnapshot: [CandidateGroup] = []

    /// 仅在 workQueue 上读写。
    private var isDriving = false

    init(
        photoLibrary: PhotoLibraryServiceProtocol,
        database: PhotoLibraryDatabase,
        store: KeyValueStore,
        imageDataLoader: @escaping (String) -> Data? = { _ in nil },
        hashComputer: @escaping (Data) -> String? = { _ in nil },
        workQueue: DispatchQueue = DispatchQueue(label: "com.aiphotoinbox.ScanningEngine", qos: .userInitiated)
    ) {
        self.photoLibrary = photoLibrary
        self.database = database
        self.workQueue = workQueue
        self.imageDataLoader = imageDataLoader
        self.hashComputer = hashComputer
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

    /// 候选组快照（hashing 阶段产出）。
    var candidateGroups: [CandidateGroup] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return candidateGroupsSnapshot
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
        // 杀进程续跑：hashing 阶段的内存快照随进程消失，重拉元数据重建
        // （元数据拉取廉价；已算哈希从 featureprints 表复用，见 runHashingStage）。
        if machine.phase == .hashing && fetchedRecords.isEmpty {
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
            case .embedding, .clustering, .scoring:
                // TODO(T05/T06/T09): 各阶段真实计算接入后替换占位推进。
                machine.advance()
                publishSnapshot()
                reportProgress()
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
                    data: Data(hash.utf8),
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
