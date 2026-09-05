// MARK: - GroupScoring
// 职责：scoring 阶段的组内评分——KeepScore 接线（四维特征 + 冗余度）、
//       Best Shot 标记、预删除候选集（强制过 SafetyRules）。
//       纯函数：特征一律经值对象传入，Core 层零 Vision/Photos 类型。
// 任务卡：T09。
//
// 铁律：预选 ≠ 删除。本层产出只是"建议清单"，任何下游（规则或 LLM）
// 都无权绕过 SafetyRules；系统确认框是唯一删除通道。

import Foundation

/// 一个组内成员的评分产物。
struct ScoredMember: Equatable {
    let record: AssetRecord
    /// 保留分 [0,1]（KeepScore 输出）。
    let score: Double
    /// 组内保留分最高者（Best Shot）。同分时取拍摄时间最新。
    let isBestShot: Bool
}

/// 评分后的候选组：排序视图 + 预删除候选 id 集。
struct ScoredGroup: Equatable {
    let groupID: String
    let reason: String
    /// 组内成员按保留分降序（Best Shot 在首；同分按时间新→旧）。
    let members: [ScoredMember]
    /// 通过 SafetyRules 的预删除候选（不含 Best Shot），保持分数降序。
    let preselectableIDs: [String]

    var bestShot: ScoredMember? { members.first(where: \.isBestShot) }
}

enum GroupScoring {

    /// 评一个组。
    /// - Parameters:
    ///   - featuresByID: 各资产四维特征（缺失维度由 KeepScore 输入侧补中性值）。
    ///   - hashByID / embeddingByID: 冗余度计算输入（优先 embedding，回退 pHash）。
    ///   - hasUserData: 冷启动开关——false 时 favoriteBoost 翻倍（V1 恒 false，
    ///     用户反馈历史属 T14 之后）。
    static func score(
        group: CandidateGroup,
        featuresByID: [String: VisionAnalysisResult],
        hashByID: [String: String],
        embeddingByID: [String: [Double]],
        hasUserData: Bool = false
    ) -> ScoredGroup {
        let neutral = VisionAnalysisResult(clarity: 0.5, aesthetics: 0.5, faceQuality: 0.5, saliency: 0.5)

        let scored: [ScoredMember] = group.members.map { member in
            let features = featuresByID[member.localIdentifier] ?? neutral
            let inputs = KeepScore.Inputs(
                clarity: features.clarity,
                faceQuality: features.faceQuality,
                aesthetics: features.aesthetics,
                saliency: features.saliency,
                redundancy: redundancy(of: member, in: group, hashByID: hashByID, embeddingByID: embeddingByID),
                isFavorite: member.favorite
            )
            return ScoredMember(
                record: member,
                score: KeepScore.score(inputs: inputs, hasUserData: hasUserData),
                isBestShot: false
            )
        }

        // 排序：分数降序 → 同分取时间新→旧 → 再同 id 字典序（完全确定性）。
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsDate = lhs.record.creationDate ?? .distantPast
            let rhsDate = rhs.record.creationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.record.localIdentifier < rhs.record.localIdentifier
        }

        var flagged = sorted
        guard !flagged.isEmpty else {
            return ScoredGroup(groupID: group.id, reason: group.reason, members: [], preselectableIDs: [])
        }
        flagged[0] = ScoredMember(
            record: flagged[0].record,
            score: flagged[0].score,
            isBestShot: true
        )

        let preselectable = preselectableIDs(for: flagged)

        return ScoredGroup(
            groupID: group.id,
            reason: group.reason,
            members: flagged,
            preselectableIDs: preselectable
        )
    }

    /// 根据已按保留分排序的成员重建预删除集合。
    /// 删除后刷新内存视图时复用这条规则，避免旧候选 id 残留或绕过 70% 上限。
    static func preselectableIDs(for members: [ScoredMember]) -> [String] {
        guard !members.isEmpty else { return [] }
        let group = CandidateGroup(
            id: "preselect",
            members: members.map(\.record),
            reason: ""
        )
        let allowedIDs = Set(SafetyRules.preselectableMembers(in: group).map(\.localIdentifier))
        // 正常产物中 Best Shot 在首位；同时按标记兜底，避免调用方传入顺序
        // 异常时把 Best Shot 放进自动删除集合。
        let bestID = members.first(where: \.isBestShot)?.record.localIdentifier
            ?? members.first?.record.localIdentifier
        let eligible = members.compactMap { member -> String? in
            guard member.record.localIdentifier != bestID,
                  allowedIDs.contains(member.record.localIdentifier) else { return nil }
            return member.record.localIdentifier
        }
        let maxCount = Int(floor(Double(members.count) * AppConfig.maxPreselectedDeletionRatio))
        return Array(eligible.suffix(min(maxCount, eligible.count)))
    }

    /// 组内冗余度 [0,1]：与其他成员相似度的均值（0=独一无二，1=完全重复）。
    /// 距离来源优先 embedding（单位向量欧氏 ∈[0,2] → 相似度 = 1 − 距离/2），
    /// 回退 pHash（相似度 = 1 − 汉明距离/总位数）。两两不可比的对跳过；
    /// 无任何可比对（单例/无特征）→ 0（不惩罚）。
    static func redundancy(
        of member: AssetRecord,
        in group: CandidateGroup,
        hashByID: [String: String],
        embeddingByID: [String: [Double]]
    ) -> Double {
        let others = group.members.filter { $0.localIdentifier != member.localIdentifier }
        guard !others.isEmpty else { return 0 }

        var similarities: [Double] = []
        similarities.reserveCapacity(others.count)
        for other in others {
            if let similarity = pairSimilarity(member, other, hashByID: hashByID, embeddingByID: embeddingByID) {
                similarities.append(similarity)
            }
        }
        guard !similarities.isEmpty else { return 0 }
        return similarities.reduce(0, +) / Double(similarities.count)
    }

    private static func pairSimilarity(
        _ a: AssetRecord,
        _ b: AssetRecord,
        hashByID: [String: String],
        embeddingByID: [String: [Double]]
    ) -> Double? {
        if let va = embeddingByID[a.localIdentifier],
           let vb = embeddingByID[b.localIdentifier],
           let distance = EmbeddingMath.euclidean(va, vb) {
            return max(0, min(1, 1 - distance / 2))   // 单位向量欧氏 ∈[0,2]
        }
        if let ha = hashByID[a.localIdentifier],
           let hb = hashByID[b.localIdentifier],
           let distance = HashDistance.hamming(hexA: ha, hexB: hb) {
            let totalBits = Double(ha.count * 4)
            guard totalBits > 0 else { return nil }
            return max(0, min(1, 1 - Double(distance) / totalBits))
        }
        return nil
    }
}
