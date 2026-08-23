// MARK: - LowQualityDetector
// 职责：低质量检测的纯判定逻辑（T16）——clarity 阈值判模糊、曝光占比判
//       过曝/欠曝、双命中取主导者；夜间白名单豁免与红线过滤。
// 任务卡：T16。阈值全部来自 AppConfig（来源注释见彼处）。

import Foundation

/// 低质量种类（P6 三分区；rawValue 落 decisions reason）。
enum LowQualityKind: String, Equatable {
    case blurry
    case overexposed
    case underexposed
}

/// 一个低质量候选：kind 决定页面分区；isNightExempt 只展示角标，永不进预选集合
/// （红线 6：intentional 模糊/夜景长曝不推荐删除）。
struct LowQualityCandidate: Equatable {
    let record: AssetRecord
    let kind: LowQualityKind
    /// 触发时的 clarity 分（调试与解释文案用）。
    let clarity: Double
    let isNightExempt: Bool
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
        let isBlurry = clarity < AppConfig.lowQualityClarityThreshold
        let isOver = (overRatio ?? 0) >= AppConfig.lowQualityOverExposedRatioThreshold
        let isUnder = (underRatio ?? 0) >= AppConfig.lowQualityUnderExposedRatioThreshold

        switch (isBlurry, isOver, isUnder) {
        case (false, false, false):
            return nil
        case (true, false, false):
            return .blurry
        case (false, true, false):
            return .overexposed
        case (false, false, true):
            return .underexposed
        case (_, true, _) where (overRatio ?? 0) >= 0.5:
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
        !candidate.record.favorite && !candidate.record.isEdited && !candidate.isNightExempt
    }
}
