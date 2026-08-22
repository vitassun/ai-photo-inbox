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
        do {
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            let request = VNGenerateImageFeaturePrintRequest()
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                throw VisionAnalysisError.noObservation
            }
            completion(.success(try Self.extractVector(observation)))
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: 特征向量提取

    enum VisionAnalysisError: Error {
        case noObservation
        case unsupportedElementType
        case emptyFeaturePrint
    }

    /// VNFeaturePrintObservation → [Double]。公开 API 无逐元素访问器，
    /// 标准做法是从 data 缓冲按 elementType 整块拷贝
    /// （float=4 字节/元素，double=8 字节/元素）。
    static func extractVector(_ observation: VNFeaturePrintObservation) throws -> [Double] {
        let count = observation.elementCount
        guard count > 0 else { throw VisionAnalysisError.emptyFeaturePrint }
        let data = observation.data
        guard data.count == count * VNElementTypeSize(observation.elementType) else {
            throw VisionAnalysisError.emptyFeaturePrint
        }
        switch observation.elementType {
        case .float:
            return data.withUnsafeBytes { raw in
                let pointer = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                return UnsafeBufferPointer(start: pointer, count: count).map(Double.init)
            }
        case .double:
            return data.withUnsafeBytes { raw in
                let pointer = raw.baseAddress!.assumingMemoryBound(to: Double.self)
                return UnsafeBufferPointer(start: pointer, count: count).map { $0 }
            }
        default:
            throw VisionAnalysisError.unsupportedElementType
        }
    }
}
