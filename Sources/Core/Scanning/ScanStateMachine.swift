// MARK: - ScanStateMachine
// 职责：扫描流水线可恢复状态机。阶段与进度持久化到 KeyValueStore 协议，
//       崩溃/杀进程后重建实例即可断点续扫（生产落 GRDB，见 T03；测试注入内存实现）。
// 任务卡：T07。纯逻辑：不 import Photos，不碰时钟与真实存储。
//
// 事务与错误语义（T07 补充验收）：
//   - 阶段 / 进度 / 暂停前阶段 / 轮次在**同一次** `setStringsAtomically` 中提交，
//     不会再出现"阶段已经切了、进度还是旧值"的中间态；
//   - 写盘失败不会被静默吞掉：`advance/pause/resume/reset/rewind` 返回成功与否，
//     失败时内存状态**回滚**到写入前，调用方不得声明阶段切换成功；
//   - 只有确认落盘成功后，进度基线（lastPersistedProgress）才前进；
//     失败的写入尝试不会污染基线，否则恢复会读到一个从未保存过的进度。

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

    /// 最近一次持久化失败的原因（nil = 无错误）。UI 据此提示"重试"。
    private(set) var lastPersistenceError: String?

    init(store: KeyValueStore) {
        self.store = store
        restoreFromStore()
    }

    /// 是否处于活动扫描阶段（可暂停、可汇报进度）。
    var isActive: Bool { phase.isActive }

    // MARK: 驱动

    /// 推进到流水线下一阶段并把进度清零。
    /// done 之后不再推进；paused 必须先 resume()。
    /// 返回是否**确实推进并落盘成功**；落盘失败时阶段回滚，返回 false。
    @discardableResult
    func advance() -> Bool {
        guard let index = Self.pipeline.firstIndex(of: phase),
              index + 1 < Self.pipeline.count else {
            return false
        }
        let next = Self.pipeline[index + 1]
        guard commit(phase: next, progress: 0) else { return false }
        phase = next
        progress = 0
        return true
    }

    /// 暂停并记录原因。仅活动阶段允许暂停（idle/done/paused 上调用返回 false）。
    /// 阶段与"暂停前阶段"在同一次提交中写入，避免恢复时读到不一致组合。
    @discardableResult
    func pause(reason: String) -> Bool {
        guard isActive else { return false }
        let paused = ScanPhase.paused(failReason: reason)
        guard commit(phase: paused, progress: progress, phaseBeforePause: phase) else {
            return false
        }
        phase = paused
        return true
    }

    /// 从暂停恢复到暂停前的阶段（进度原样保留）。未暂停时调用返回 false。
    @discardableResult
    func resume() -> Bool {
        guard case .paused = phase else { return false }
        let restored: ScanPhase
        if let saved = store.string(forKey: Keys.phaseBeforePause),
           let decoded: ScanPhase = decode(saved), decoded.isActive {
            restored = decoded
        } else {
            // 恢复点丢失（理论上不该发生）：退回流水线第一个活动阶段重扫。
            restored = .fetching
        }
        guard commit(phase: restored, progress: progress, clearPhaseBeforePause: true) else {
            return false
        }
        phase = restored
        return true
    }

    /// 复位到 idle（全新一轮扫描的起点），进度清零并持久化。
    /// 仅 done/idle 允许复位；paused 应走 resume()，活动阶段不允许打断式复位。
    /// 返回是否实际复位。
    @discardableResult
    func reset() -> Bool {
        guard phase == .done || phase == .idle else { return false }
        guard commit(phase: .idle, progress: 0, clearPhaseBeforePause: true) else {
            return false
        }
        phase = .idle
        progress = 0
        return true
    }

    /// 更新当前阶段进度（0~1，越界钳制）。非活动阶段忽略。
    ///
    /// 节流：内存进度每次都更新（UI 需要顺滑），磁盘只在阶段边界、
    /// 暂停和每约 2% 变化时落盘；落盘失败不阻断扫描，
    /// 但**不会**推进 `lastPersistedProgress` 基线。
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
    @discardableResult
    func resetToIdle() -> Bool {
        guard commit(phase: .idle, progress: 0, clearPhaseBeforePause: true) else {
            return false
        }
        phase = .idle
        progress = 0
        return true
    }

    /// 恢复时发现后续阶段所需的中间特征不完整，回退到指定活动阶段重建。
    /// 这是内部恢复语义，不允许跳到 idle/done/paused，避免绕过正常流水线。
    @discardableResult
    func rewind(to target: ScanPhase) -> Bool {
        guard target.isActive else { return false }
        guard commit(phase: target, progress: 0) else { return false }
        phase = target
        progress = 0
        return true
    }

    // MARK: 持久化

    /// 一次事务提交阶段 + 进度 + （可选）暂停前阶段 + 版本号。
    ///
    /// 返回是否整批落盘成功。失败时不做任何内存状态变更——调用方必须先
    /// 检查返回值再更新自己的状态，保证"内存与磁盘不会各说各话"。
    private func commit(
        phase newPhase: ScanPhase,
        progress newProgress: Double,
        phaseBeforePause: ScanPhase? = nil,
        clearPhaseBeforePause: Bool = false
    ) -> Bool {
        guard let phaseText = encode(newPhase) else {
            recordPersistenceError("扫描状态序列化失败")
            return false
        }
        var values: [String: String?] = [
            Keys.version: String(Self.featureVersion),
            Keys.phase: phaseText,
            Keys.progress: String(newProgress),
        ]
        if let phaseBeforePause, let text = encode(phaseBeforePause) {
            values[Keys.phaseBeforePause] = text
        } else if clearPhaseBeforePause {
            values[Keys.phaseBeforePause] = nil
        }
        guard store.setStringsAtomically(values) else {
            recordPersistenceError("扫描状态保存失败，请检查存储空间后重试")
            return false
        }
        lastPersistedProgress = newProgress
        lastPersistenceError = nil
        return true
    }

    private func restoreFromStore() {
        let savedVersion = store.string(forKey: Keys.version).flatMap(Int.init)
        guard savedVersion == Self.featureVersion else {
            // 全新安装或版本不符：丢弃旧进度，写入当前版本基线。
            phase = .idle
            progress = 0
            lastPersistedProgress = 0
            // 版本基线写入失败不影响本轮可用性：内存已回到 idle，
            // 下次启动会再尝试一次，因此只记录错误不阻断。
            let baseline: [String: String?] = [
                Keys.version: String(Self.featureVersion),
                Keys.phase: encode(.idle),
                Keys.progress: "0",
                Keys.phaseBeforePause: nil,
            ]
            if !store.setStringsAtomically(baseline) {
                recordPersistenceError("扫描状态初始化失败，请检查存储空间后重试")
            }
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

    /// 只更新进度键。失败时不推进基线，也不覆盖已有错误信息。
    private func persistProgressIfNeeded(force: Bool) {
        let shouldPersist = force
            || lastPersistedProgress == nil
            || abs(progress - (lastPersistedProgress ?? 0))
                >= AppConfig.scanProgressPersistenceStep
        guard shouldPersist else { return }
        guard store.setString(String(progress), forKey: Keys.progress) else {
            recordPersistenceError("扫描进度保存失败，请检查存储空间后重试")
            return
        }
        lastPersistedProgress = progress
    }

    private func recordPersistenceError(_ message: String) {
        lastPersistenceError = message
    }

    private func encode(_ value: ScanPhase) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decode<T: Decodable>(_ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
