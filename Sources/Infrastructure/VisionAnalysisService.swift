// MARK: - VisionAnalysisService
// 职责：VisionAnalysisServiceProtocol 的 Vision 真实现——
//       analyze 一次解码串联人脸质量/显著性/iOS18 美学 + T06 DSP 清晰度；
//       computeEmbedding 走 VNGenerateImageFeaturePrintRequest。
// 任务卡：T05（embedding）、T08（analyze 全链）。
//
// 失败隔离：单个请求失败只影响自己那一维（聚合层回退中性值 0.5），
// 绝不让管线崩；模拟器跑不了美学请求（Apple 确认的预期行为），
// 因此 CI 上 aesthetics 恒为中性值，真机才有真实分数。

import Foundation
import CoreGraphics
import ImageIO
import Vision

final class VisionAnalysisService: VisionAnalysisServiceProtocol {

    func analyze(
        imageData: Data,
        completion: @escaping (Result<VisionAnalysisResult, Error>) -> Void
    ) {
        // 不许逐张串行阻塞主线程（T08 边界）：解码与请求全部在工作队列执行，
        // 完成回调也在工作线程投递（调用方按需切主线程）。
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Self.analyzeSync(imageData: imageData))
        }
    }

    /// 同步分析主体（内部可见，便于测试直调）。
    static func analyzeSync(imageData: Data) -> Result<VisionAnalysisResult, Error> {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(VisionAnalysisError.imageDecodeFailed)
        }

        var clarity: Double?
        var aesthetics: Double?
        var faceQuality: Double?
        var saliency: Double?

        // clarity：T06 自实现 DSP（纯本地计算，不依赖 Vision）。
        if let gray = grayPixels(from: cgImage, side: 64) {
            clarity = ImageQualityDSP.clarityScore(grayPixels: gray, width: 64, height: 64)
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        // faceQuality：取画面中最好的一张脸（Best Shot 语义）。
        if let request = try? VNDetectFaceCaptureQualityRequest(),
           (try? handler.perform([request])) != nil {
            let qualities = (request.results as? [VNFaceObservation])?
                .compactMap(\.faceCaptureQuality)
                .map(Double.init) ?? []
            faceQuality = qualities.max()
        }

        // saliency：注意力显著性最高置信度。
        if let request = try? VNGenerateAttentionBasedSaliencyImageRequest(),
           (try? handler.perform([request])) != nil {
            let observation = request.results?.first as? VNSaliencyImageObservation
            saliency = observation?.salientObjects.map(\.confidence).max().map(Double.init)
        }

        // aesthetics：iOS18 美学总分 [-1,1] → [0,1]。模拟器不支持 → 保持 nil → 中性值。
        if let request = try? VNCalculateImageAestheticsScoresRequest(),
           (try? handler.perform([request])) != nil {
            if let observation = request.results?.first as? ImageAestheticsScoresObservation {
                aesthetics = (Double(observation.overallScore) + 1) / 2
            }
        }

        return .success(VisionResultAggregator.aggregate(
            clarity: clarity,
            aesthetics: aesthetics,
            faceQuality: faceQuality,
            saliency: saliency
        ))
    }

    // MARK: 灰度采样（DSP 输入）

    /// CGImage 重绘到 side×side RGBA 后转亮度缓冲。
    private static func grayPixels(from cgImage: CGImage, side: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buffer = context.data else { return nil }
        let rgba = buffer.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var luma: [UInt8] = []
        luma.reserveCapacity(side * side)
        for pixel in 0..<(side * side) {
            let offset = pixel * 4
            let value = (299 * Int(rgba[offset])
                + 587 * Int(rgba[offset + 1])
                + 114 * Int(rgba[offset + 2])) / 1000
            luma.append(UInt8(max(0, min(255, value))))
        }
        return luma
    }

    func computePerceptualHash(
        imageData: Data,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // 实现体在 PerceptualHash（T04 的自实现 DCT pHash，纯函数核心）。
        if let hash = PerceptualHash.hash(fromEncodedImageData: imageData) {
            completion(.success(hash))
        } else {
            completion(.failure(VisionAnalysisError.imageDecodeFailed))
        }
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
        case imageDecodeFailed
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
