// MARK: - KeepScore
// 职责：保留分评分引擎——六维权重 + 纯函数打分 + 冷启动规则。
//       输出仅用于组内排序与预选建议，绝不直接决定删除（删除走 T10 系统确认框）。
// 任务卡：T06（评分引擎；权重初值靠人工抽检校准）。

import Foundation

/// 六项权重。初值为拍脑袋起点，V1 阶段用真实相册回归集校准（见可行性报告 §2.2）。
struct KeepWeights: Equatable {
    /// 清晰度（拉普拉斯方差归一化 0~1，T05 产出）。
    var clarity: Double = 0.25
    /// 人脸质量（有人脸且睁眼/朝向好加分；无人脸场景给中性值）。
    var faceQuality: Double = 0.20
    /// 美学评分（iOS 18 VNCalculateImageAestheticsScoresRequest 输出归一化 0~1）。
    var aesthetics: Double = 0.25
    /// 显著性（主体突出程度 / saliency 中心偏移）。
    var saliency: Double = 0.15
    /// 冗余惩罚：与组内其他成员越相似扣越多（输入为冗余度 0~1）。
    var redundancyPenalty: Double = 0.10
    /// 收藏加权：收藏资产的加分。冷启动期翻倍（见 KeepScore.score）。
    var favoriteBoost: Double = 0.05
}

enum KeepScore {
    /// 打分输入，除 isFavorite 外全部 0~1 归一化；
    /// 某能力 V1 未实现时传中性值 0.5，不得传 0 拉低所有照片。
    struct Inputs: Equatable {
        var clarity: Double
        var faceQuality: Double
        var aesthetics: Double
        var saliency: Double
        /// 组内冗余度：0 = 独一无二，1 = 与他人完全重复。
        var redundancy: Double
        var isFavorite: Bool
    }

    /// 计算保留分，结果钳制在 0~1。
    ///
    /// 冷启动规则：hasUserData == false（用户还没有收藏/编辑历史可学）时，
    /// 收藏是唯一可信的显式偏好信号 → favoriteBoost 权重翻倍。
    static func score(
        inputs: Inputs,
        weights: KeepWeights = KeepWeights(),
        hasUserData: Bool = true
    ) -> Double {
        var effectiveWeights = weights
        if !hasUserData {
            effectiveWeights.favoriteBoost *= 2
        }

        var value = inputs.clarity * effectiveWeights.clarity
            + inputs.faceQuality * effectiveWeights.faceQuality
            + inputs.aesthetics * effectiveWeights.aesthetics
            + inputs.saliency * effectiveWeights.saliency
        value -= inputs.redundancy * effectiveWeights.redundancyPenalty
        if inputs.isFavorite {
            value += effectiveWeights.favoriteBoost
        }
        // 钳制到 [0, 1]：冗余惩罚可能把分数打成负数，不能让负分污染排序语义。
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
