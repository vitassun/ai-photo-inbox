// MARK: - VisionAnalysisServiceProtocol
// 职责：Vision 能力的协议抽象（清晰度/美学/人脸质量/显著性/哈希/嵌入）。
//       真实现见 Infrastructure/VisionAnalysisService（iOS 18 美学 API 在那边落地）。
// 任务卡：T05。

import Foundation

/// 单张图的全套分析产物。全部归一化 0~1；
/// 能力缺失时给中性值 0.5，不得给 0（会系统性拉低所有照片）。
struct VisionAnalysisResult: Codable, Equatable {
    var clarity: Double
    var aesthetics: Double
    var faceQuality: Double
    var saliency: Double
}

protocol VisionAnalysisServiceProtocol {
    /// 对单张图跑全套分析（清晰度/美学/人脸/显著性一次串联）。
    /// imageData 为 JPEG/PNG 原始字节——协议层不 import UIImage，保持可测试。
    func analyze(
        imageData: Data,
        completion: @escaping (Result<VisionAnalysisResult, Error>) -> Void
    )

    /// 计算感知哈希（pHash/dHash 十六进制串），用于分桶内粗筛去重。
    func computePerceptualHash(
        imageData: Data,
        completion: @escaping (Result<String, Error>) -> Void
    )

    /// 计算 featureprint 嵌入向量，用于相似度精比聚类。
    func computeEmbedding(
        imageData: Data,
        completion: @escaping (Result<[Double], Error>) -> Void
    )
}
