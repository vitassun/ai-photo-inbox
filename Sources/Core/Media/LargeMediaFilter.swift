// MARK: - LargeMediaFilter
// 职责：大媒体清理候选——估算体积 ≥ 阈值打标 + 排序，并执行红线豁免
//       （收藏/编辑过永不入选；已进相似候选组的资产让位给组流程，
//       "组内唯一"红线由 SafetyRules 在组流程内把关）。
// 任务卡：T07。独立于相似组流程，但同样尊重 SafetyRules。

import Foundation

/// 一个大媒体清理候选项。
struct LargeMediaCandidate: Codable, Equatable {
    let record: AssetRecord
    let estimatedBytes: Int64
    /// 未被相似组认领的大媒体没有已知替代品，只能展示，不能被全选建议预选。
    /// 默认值保持旧的纯逻辑构造调用兼容；真实扫描时由引擎显式置位。
    let isOnlyInGroup: Bool = false

    init(record: AssetRecord, estimatedBytes: Int64, isOnlyInGroup: Bool = false) {
        self.record = record
        self.estimatedBytes = estimatedBytes
        self.isOnlyInGroup = isOnlyInGroup
    }

    var canPreselect: Bool {
        !isOnlyInGroup && !record.favorite && !record.isEdited && record.locallyAvailable
    }
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
        records.compactMap { record -> LargeMediaCandidate? in
            // 红线 1/2：收藏过、编辑过的资产永不进入任何预选集合。
            guard !record.favorite, !record.isEdited else { return nil }
            // 用户明确保留过的资产在重扫时也不得重新出现。
            guard !idsWithKeepDecision.contains(record.localIdentifier) else { return nil }
            // 让位相似组流程：同一资产不同时出现在两个删除候选视图里。
            guard !idsInCandidateGroups.contains(record.localIdentifier) else { return nil }
            guard let bytes = MediaSizeEstimator.estimatedBytes(for: record),
                  bytes >= thresholdBytes else { return nil }
            // 该过滤器接收的是“未被相似组认领”的资产，因此没有已知替代品；
            // 结果只用于展示和用户手动选择，不能成为全选建议。
            return LargeMediaCandidate(record: record, estimatedBytes: bytes, isOnlyInGroup: true)
        }
        .sorted { $0.estimatedBytes > $1.estimatedBytes }
    }
}
