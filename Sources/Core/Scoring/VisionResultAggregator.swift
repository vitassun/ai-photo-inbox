// MARK: - VisionResultAggregator
// 职责：把各 Vision 维度的原始输出聚合为 VisionAnalysisResult。
//       纯函数：只收 Double 可选值，零 Vision 依赖（Core 层铁律）。
// 任务卡：T08。
//
// 铁律：失败/能力缺失（nil）一律回退中性值 0.5，绝不按 0 分处理——
//       0分会系统性拉低所有照片（协议注释约定）；模拟器跑不了美学请求
//       也因此天然安全。

import Foundation

enum VisionResultAggregator {

    /// 中性回退值（协议注释冻结：能力缺失给 0.5，不给 0）。
    static let neutralScore = 0.5

    /// 聚合四维。nil 视作该维度失败/缺失 → 0.5；有值钳制到 [0,1]。
    /// - Parameters:
    ///   - clarity: T06 DSP 拉普拉斯方差得分（已归一化或 nil）。
    ///   - aesthetics: iOS18 美学 overallScore 已映射到 [0,1]（模拟器恒 nil）。
    ///   - faceQuality: 人脸捕获质量最大值；无人脸传 nil。
    ///   - saliency: 显著性置信度；无观察传 nil。
    static func aggregate(
        clarity: Double?,
        aesthetics: Double?,
        faceQuality: Double?,
        saliency: Double?
    ) -> VisionAnalysisResult {
        VisionAnalysisResult(
            clarity: clamped(clarity),
            aesthetics: clamped(aesthetics),
            faceQuality: clamped(faceQuality),
            saliency: clamped(saliency)
        )
    }

    private static func clamped(_ value: Double?) -> Double {
        guard let value else { return neutralScore }
        return min(1, max(0, value))
    }
}
