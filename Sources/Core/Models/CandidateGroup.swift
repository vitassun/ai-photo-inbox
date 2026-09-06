// MARK: - CandidateGroup
// 职责：一个"候选组"——分组算法的产出单元（时间连拍/相似重复/同场景截图），
//       供评分引擎（T06）与安全规则（T10）消费。
// 任务卡：T04（分组算法）。

import Foundation

/// 一组互为相似候选的资产。
struct CandidateGroup: Codable, Equatable {
    /// 组标识（V1 可用 "timebucket-<起始时间戳>" 之类的确定性字符串）。
    let id: String
    /// 组内成员完整记录，顺序即时间先后（旧 → 新）。
    let members: [AssetRecord]
    /// 分组依据的可读标签（如 "时间连拍 30min"），日志与调试用。
    let reason: String

    /// 成员 localIdentifier 列表（便捷视图）。
    var memberIDs: [String] { members.map { $0.localIdentifier } }

    var count: Int { members.count }
}
