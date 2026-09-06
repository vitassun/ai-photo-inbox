// MARK: - LowQualityDetector
// 职责：低质量检测的纯判定逻辑（T16）——clarity 阈值判模糊、曝光占比判
//       过曝/欠曝、双命中取主导者；夜间白名单豁免与红线过滤。
// 任务卡：T16。阈值全部来自 AppConfig（来源注释见彼处）。

import Foundation

/// 低质量种类（P6 三分区；rawValue 落 decisions reason）。
enum LowQualityKind: String, Codable, Equatable {
    case blurry
    case overexposed
    case underexposed
}

/// 一个低质量候选：kind 决定页面分区；isNightExempt 只展示角标，永不进预选集合
/// （红线 6：intentional 模糊/夜景长曝不推荐删除）。
struct LowQualityCandidate: Codable, Equatable {
    let record: AssetRecord
    let kind: LowQualityKind
    /// 触发时的 clarity 分（调试与解释文案用）。
    let clarity: Double
    let isNightExempt: Bool
    /// 低质量 pass 只处理未被相似组认领的资产。此类资产没有已知替代品，
    /// 因而可以展示给用户，但永远不能被“全选建议”自动预选。
    /// 默认值保留旧的纯逻辑构造调用；真实扫描时由引擎显式置为 true。
    let isOnlyInGroup: Bool

    init(
        record: AssetRecord,
        kind: LowQualityKind,
        clarity: Double,
        isNightExempt: Bool,
        isOnlyInGroup: Bool = false
    ) {
        self.record = record
        self.kind = kind
        self.clarity = clarity
        self.isNightExempt = isNightExempt
        self.isOnlyInGroup = isOnlyInGroup
    }

    private enum CodingKeys: String, CodingKey {
        case record, kind, clarity, isNightExempt, isOnlyInGroup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decode(AssetRecord.self, forKey: .record)
        kind = try container.decode(LowQualityKind.self, forKey: .kind)
        clarity = try container.decode(Double.self, forKey: .clarity)
        isNightExempt = try container.decode(Bool.self, forKey: .isNightExempt)
        isOnlyInGroup = try container.decodeIfPresent(Bool.self, forKey: .isOnlyInGroup) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(record, forKey: .record)
        try container.encode(kind, forKey: .kind)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(isNightExempt, forKey: .isNightExempt)
        try container.encode(isOnlyInGroup, forKey: .isOnlyInGroup)
    }

    var canPreselect: Bool {
        LowQualityDetector.preselectable(self)
    }
}

enum LowQualityDetector {

    /// 单张判定。返回 kind；不满足任何低质条件返回 nil。
    /// 规则（完全确定性）：
    ///   1) clarity < 阈值 → 模糊候选；
    ///   2) 过曝占比 ≥ 阈值 → 过曝候选；
    ///   3) 欠曝占比 ≥ 阈值 → 欠曝候选；
    ///   4) 模糊与曝光同时命中：曝光占比 ≥ 0.5 视为曝光主导，
    ///      否则模糊主导（过曝优先于欠曝——同图两可时取更"废"的过曝）。
    static func detect(
        clarity: Double,
        overRatio: Double?,
        underRatio: Double?
    ) -> LowQualityKind? {
        // 视觉分析失败或数据源返回异常浮点数时，按中性值处理；比例始终限制在
        // [0, 1]，避免 +∞ 等脏数据直接制造删除候选。
        let safeClarity = clarity.isFinite ? clarity : 0.5
        let safeOverRatio = sanitizedRatio(overRatio)
        let safeUnderRatio = sanitizedRatio(underRatio)
        let isBlurry = safeClarity < AppConfig.lowQualityClarityThreshold
        let isOver = safeOverRatio >= AppConfig.lowQualityOverExposedRatioThreshold
        let isUnder = safeUnderRatio >= AppConfig.lowQualityUnderExposedRatioThreshold

        switch (isBlurry, isOver, isUnder) {
        case (false, false, false):
            return nil
        case (true, false, false):
            return .blurry
        case (false, true, false):
            return .overexposed
        case (false, false, true):
            return .underexposed
        case (true, true, false) where safeOverRatio >= AppConfig.lowQualityExposureDominanceRatio:
            // 模糊同时伴随大面积过曝时，曝光问题更具决定性；
            // 过曝占比不足主导阈值则保留模糊标签（见 default）。
            return .overexposed
        case (false, true, true):
            // 两种曝光异常同时达到阈值时，选择占比更大的实际问题；
            // 不能落入 default 把一张清晰照片错误标成模糊。
            return safeOverRatio >= safeUnderRatio ? .overexposed : .underexposed
        case (true, true, true) where safeOverRatio >= AppConfig.lowQualityExposureDominanceRatio:
            return .overexposed
        case (true, _, true):
            // 糊 + 欠曝且过曝未达主导：欠曝更难挽回，取欠曝。
            return .underexposed
        default:
            return .blurry
        }
    }

    /// 预选集合红线（SafetyRules 同源口径）：收藏/编辑过永不入选；
    /// 夜间豁免只标记不预选。
    static func preselectable(_ candidate: LowQualityCandidate) -> Bool {
        !candidate.record.favorite && !candidate.record.isEdited
            && !candidate.isNightExempt && !candidate.isOnlyInGroup
    }

    private static func sanitizedRatio(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
