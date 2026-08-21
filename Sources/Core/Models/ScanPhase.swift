// MARK: - ScanPhase
// 职责：扫描流水线阶段的穷举枚举；Codable 序列化后写入 KeyValueStore 断点续扫。
// 任务卡：T07（扫描状态机）。

import Foundation

/// 扫描阶段。流水线固定顺序：
/// idle → fetching → hashing → embedding → clustering → scoring → done。
enum ScanPhase: Equatable, Codable {
    /// 尚未开始 / 进度被重置。
    case idle
    /// 从 PhotoKit 拉取元数据（AssetRecord）。
    case fetching
    /// 计算感知哈希（pHash 粗筛）。
    case hashing
    /// 计算 featureprint 嵌入向量。
    case embedding
    /// 相似度聚类成组。
    case clustering
    /// 组内保留分评分与预选。
    case scoring
    /// 本轮全库扫描完成。
    case done
    /// 因错误或用户操作暂停；failReason 供 UI 展示与恢复决策。
    case paused(failReason: String)

    /// 是否处于正在干活的活动阶段（可暂停、可汇报进度）。
    var isActive: Bool {
        switch self {
        case .fetching, .hashing, .embedding, .clustering, .scoring:
            return true
        case .idle, .done, .paused:
            return false
        }
    }
}
