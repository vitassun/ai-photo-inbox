// MARK: - ScanStateMachine
// 职责：扫描流水线可恢复状态机。阶段与进度持久化到 KeyValueStore 协议，
//       崩溃/杀进程后重建实例即可断点续扫（生产落 GRDB，见 T03；测试注入内存实现）。
// 任务卡：T07。纯逻辑：不 import Photos，不碰时钟与真实存储。

import Foundation

final class ScanStateMachine {
    /// 特征/持久化格式版本。字段语义变更时 +1；
    /// 恢复时版本不符则丢弃旧进度从头重扫（避免脏数据混入新逻辑）。
    // 预选安全语义、结果快照格式和特征复用边界发生过变化；提高版本后，
    // 旧进度/特征会在下次启动时安全回到 idle，避免混用旧算法产物。
    static let featureVersion = 2

    /// 流水线固定顺序（与 ScanPhase 注释保持一致）。
    static let pipeline: [ScanPhase] = [
        .idle, .fetching, .hashing, .embedding, .clustering, .scoring, .done,
    ]

    private enum Keys {
        static let phase = "scan.phase"
        static let progress = "scan.progress"
        static let version = "scan.featureVersion"
        static let phaseBeforePause = "scan.phaseBeforePause"
    }

    private let store: KeyValueStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastPersistedProgress: Double?

    private(set) var phase: ScanPhase = .idle
    private(set) var progress: Double = 0

    init(store: KeyValueStore) {
        self.store = store
        restoreFromStore()
    }

    /// 是否处于活动扫描阶段（可暂停、可汇报进度）。
    var isActive: Bool { phase.isActive }

    // MARK: 驱动

    /// 推进到流水线下一阶段并把进度清零。
    /// done 之后不再推进；paused 必须先 resume()。返回是否实际推进。
    @discardableResult
    func advance() -> Bool {
        guard let index = Self.pipeline.firstIndex(of: phase),
              index + 1 < Self.pipeline.count else {
            return false
        }
        phase = Self.pipeline[index + 1]
        progress = 0
        persist()
        return true
    }

    /// 暂停并记录原因。仅活动阶段允许暂停（idle/done/paused 上调用返回 false）。
    @discardableResult
    func pause(reason: String) -> Bool {
        guard isActive else { return false }
        store.setString(encode(phase), forKey: Keys.phaseBeforePause)
        phase = .paused(failReason: reason)
        persist()
        return true
    }

    /// 从暂停恢复到暂停前的阶段（进度原样保留）。未暂停时调用返回 false。
    @discardableResult
    func resume() -> Bool {
        guard case .paused = phase else { return false }
        if let saved = store.string(forKey: Keys.phaseBeforePause),
           let restored: ScanPhase = decode(saved), restored.isActive {
            phase = restored
        } else {
            // 恢复点丢失（理论上不该发生）：退回流水线第一个活动阶段重扫。
            phase = .fetching
        }
        persist()
        return true
    }

    /// 复位到 idle（全新一轮扫描的起点），进度清零并持久化。
    /// 仅 done/idle 允许复位；paused 应走 resume()，活动阶段不允许打断式复位。
    /// 返回是否实际复位。
    @discardableResult
    func reset() -> Bool {
        guard phase == .done || phase == .idle else { return false }
        phase = .idle
        progress = 0
        persist()
        return true
    }

    /// 更新当前阶段进度（0~1，越界钳制）。非活动阶段忽略。
    func setProgress(_ value: Double) {
        guard isActive else { return }
        guard value.isFinite else {
            progress = 0
            persistProgressIfNeeded(force: true)
            return
        }
        progress = min(max(value, 0), 1)
        persistProgressIfNeeded(force: progress == 0 || progress >= 1)
    }

    /// 手动重置到 idle（用于完成后的全新扫描）。
    func resetToIdle() {
        phase = .idle
        progress = 0
        persist()
    }

    /// 恢复时发现后续阶段所需的中间特征不完整，回退到指定活动阶段重建。
    /// 这是内部恢复语义，不允许跳到 idle/done/paused，避免绕过正常流水线。
    @discardableResult
    func rewind(to target: ScanPhase) -> Bool {
        guard target.isActive else { return false }
        phase = target
        progress = 0
        persist()
        return true
    }

    // MARK: 持久化

    private func restoreFromStore() {
        let savedVersion = store.string(forKey: Keys.version).flatMap(Int.init)
        guard savedVersion == Self.featureVersion else {
            // 全新安装或版本不符：丢弃旧进度，写入当前版本基线。
            phase = .idle
            progress = 0
            lastPersistedProgress = 0
            store.setString(String(Self.featureVersion), forKey: Keys.version)
            store.setString(encode(.idle), forKey: Keys.phase)
            store.setString("0", forKey: Keys.progress)
            return
        }
        if let saved = store.string(forKey: Keys.phase),
           let restored: ScanPhase = decode(saved) {
            phase = restored
        }
        if let saved = store.string(forKey: Keys.progress),
           let value = Double(saved), value.isFinite {
            progress = min(max(value, 0), 1)
        } else {
            progress = 0
        }
        lastPersistedProgress = progress
    }

    private func persist() {
        store.setString(String(Self.featureVersion), forKey: Keys.version)
        store.setString(encode(phase), forKey: Keys.phase)
        store.setString(String(progress), forKey: Keys.progress)
        lastPersistedProgress = progress
    }

    private func persistProgressIfNeeded(force: Bool) {
        let shouldPersist = force
            || lastPersistedProgress == nil
            || abs(progress - (lastPersistedProgress ?? 0))
                >= AppConfig.scanProgressPersistenceStep
        guard shouldPersist else { return }
        store.setString(String(progress), forKey: Keys.progress)
        lastPersistedProgress = progress
    }

    private func encode(_ value: ScanPhase) -> String {
        guard let data = try? encoder.encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decode<T: Decodable>(_ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
