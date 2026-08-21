// MARK: - VisionAnalysisService
// 职责：VisionAnalysisServiceProtocol 的 Vision 真实现。V1 骨架期为 TODO 占位。
// 任务卡：T05（清晰度/美学/人脸/显著性/哈希/嵌入 六项能力串联）。

import Foundation
import Vision

final class VisionAnalysisService: VisionAnalysisServiceProtocol {

    func analyze(
        imageData: Data,
        completion: @escaping (Result<VisionAnalysisResult, Error>) -> Void
    ) {
        // TODO(T05): VNImageHandler 串联四请求：
        //   清晰度 = 拉普拉斯方差（自写 DSP，CoreImage/vDSP）；
        //   美学 = CalculateImageAestheticsScoresRequest（iOS 18+，部署目标已保证）；
        //   人脸质量 = VNDetectFaceRectanglesRequest + 姿态/朝向打分；
        //   显著性 = VNGenerateAttentionBasedSaliencyImageRequest 中心偏移。
        //   全部归一化 0~1 后回调。
        fatalError("TODO(T05): 见任务卡 T05")
    }

    func computePerceptualHash(
        imageData: Data,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // TODO(T05): pHash（DCT，vDSP 加速）或 dHash，输出十六进制串 + 汉明距离比较器。
        fatalError("TODO(T05): 见任务卡 T05")
    }

    func computeEmbedding(
        imageData: Data,
        completion: @escaping (Result<[Double], Error>) -> Void
    ) {
        // TODO(T05): VNGenerateImageFeaturePrintRequest → observation.featurePrint
        //   → [Double]（距离用欧氏/余弦，阈值靠回归集调优，见可行性报告 §2.1）。
        fatalError("TODO(T05): 见任务卡 T05")
    }
}
