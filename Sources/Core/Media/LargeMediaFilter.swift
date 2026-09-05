// MARK: - LargeMediaFilter
// 职责：大媒体清理候选——估算体积 ≥ 阈值打标 + 排序，并执行红线豁免
//       （收藏/编辑过永不入选；已进相似候选组的资产让位给组流程，
//       "组内唯一"红线由 SafetyRules 在组流程内把关）。
// 任务卡：T07。独立于相似组流程，但同样尊重 SafetyRules。

import Foundation

/// 一个大媒体清理候选项。
struct LargeMediaCandidate: Equatable {
    let record: AssetRecord
    let estimatedBytes: Int64
}

enum LargeMediaFilter {

    /// 返回按估算体积降序的候选列表。
    /// - Parameters:
    ///   - idsInCandidateGroups: 已被相似组流程认领的资产 id（不重复打标）。
    static func candidates(
        from records: [AssetRecord],
        thresholdBytes: Int64 = AppConfig.largeMediaEstimatedBytesThreshold,
        idsInCandidateGroups: Set<String> = [],
        idsWithKeepDecision: Set<String> = []
    ) -> [LargeMediaCandidate] {
        records.compactMap { record in
            // 红线 1/2：收藏过、编辑过的资产永不进入任何预选集合。
            guard !record.favorite, !record.isEdited else { return nil }
            // 用户明确保留过的资产在重扫时也不得重新出现。
            guard !idsWithKeepDecision.contains(record.localIdentifier) else { return nil }
            // 让位相似组流程：同一资产不同时出现在两个删除候选视图里。
            guard !idsInCandidateGroups.contains(record.localIdentifier) else { return nil }
            guard let bytes = MediaSizeEstimator.estimatedBytes(for: record),
                  bytes >= thresholdBytes else { return nil }
            return LargeMediaCandidate(record: record, estimatedBytes: bytes)
        }
        .sorted { $0.estimatedBytes > $1.estimatedBytes }
    }
}
