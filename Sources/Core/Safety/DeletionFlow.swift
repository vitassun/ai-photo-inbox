// MARK: - DeletionFlow
// 职责：删除流的核心纯逻辑——预选集汇总、批量切分、批次顺序执行。
// 任务卡：T10。
//
// 铁律：本层产出的每个 id 都已经过 SafetyRules（T09 的 preselectableIDs
// 即 SafetyRules 过滤产物）；requestDelete 只负责把确认交给系统弹框，
// 永不静默删除。

import Foundation

enum DeletionFlow {

    /// 单次 performChanges 的批量上限（防超时；超出自动分批）。
    static let maxBatchSize = 200

    /// 从评分后的组视图汇总待删 id。preselectableIDs 在 T09 已强制过
    /// SafetyRules——这里只做汇总与去重，不做二次过滤（职责单一）。
    /// 输出保持组序 + 组内分数降序，确定性。
    static func pendingDeletionIDs(from scoredGroups: [ScoredGroup]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in scoredGroups {
            for id in group.preselectableIDs where !seen.contains(id) {
                seen.insert(id)
                result.append(id)
            }
        }
        return result
    }

    /// 把 id 集合切成 ≤ maxBatchSize 的批次，顺序稳定。
    static func batches(of identifiers: [String], maxBatchSize: Int = DeletionFlow.maxBatchSize) -> [[String]] {
        precondition(maxBatchSize >= 1, "批次上限至少为 1")
        guard !identifiers.isEmpty else { return [] }
        return stride(from: 0, to: identifiers.count, by: maxBatchSize).map {
            Array(identifiers[$0..<min($0 + maxBatchSize, identifiers.count)])
        }
    }

    /// 按批顺序执行：任一批失败即停止后续批次（续传语义——调用方以
    /// fetchAssets(matching:) 重查幸存者后重试，已删者自然消失）。
    /// - Returns: 首个失败的错误；全部成功返回 nil。已执行批次数经
    ///   onBatchCompleted 回调逐批上报（供 verdicts 落库时机）。
    static func runBatches(
        _ identifiers: [String],
        maxBatchSize: Int = DeletionFlow.maxBatchSize,
        perform: (_ batch: [String], _ batchIndex: Int) throws -> Void,
        onBatchCompleted: (_ batch: [String], _ batchIndex: Int) -> Void = { _, _ in }
    ) -> Error? {
        for (index, batch) in batches(of: identifiers, maxBatchSize: maxBatchSize).enumerated() {
            do {
                try perform(batch, index)
                onBatchCompleted(batch, index)
            } catch {
                return error
            }
        }
        return nil
    }
}
