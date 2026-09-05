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
        // salientObjects 在 Swift 里是可选数组（分析不可用时为 nil → 中性值）。
        if let request = try? VNGenerateAttentionBasedSaliencyImageRequest(),
           (try? handler.perform([request])) != nil,
           let observation = request.results?.first as? VNSaliencyImageObservation,
           let salientObjects = observation.salientObjects {
            saliency = salientObjects.map { Double($0.confidence) }.max()
        }

        // aesthetics：iOS18 美学总分 [-1,1] → [0,1]。模拟器可能返回一个
        // 看似有效但不代表真实能力的占位分数，因此必须保持 nil → 中性值；
        // 真机才读取真实结果。
        #if !targetEnvironment(simulator)
        if let request = try? VNCalculateImageAestheticsScoresRequest(),
           (try? handler.perform([request])) != nil {
            // legacy request 返回 VNImageAestheticsScoresObservation；
            // ImageAestheticsScoresObservation 是 Swift 新封装类型，强转会让
            // 真机上的结果静默丢失并一直回退到中性值。
            if let observation = request.results?.first {
                aesthetics = max(0, min(1, (Double(observation.overallScore) + 1) / 2))
            }
        }
        #endif

        return .success(VisionResultAggregator.aggregate(
            clarity: clarity,
            aesthetics: aesthetics,
            faceQuality: faceQuality,
            saliency: saliency
        ))
    }

    // MARK: 灰度采样（DSP 输入）

    /// 编码图像字节 → side×side 灰度采样（T16 曝光探测入口）。
    /// 解码失败返回 nil。
    static func grayPixelsSync(
        imageData: Data,
        side: Int
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = grayPixels(from: cgImage, side: side) else {
            return nil
        }
        return (pixels, side, side)
    }

    /// CGImage 重绘到 side×side RGBA 后转亮度缓冲。
    static func grayPixels(from cgImage: CGImage, side: Int) -> [UInt8]? {
        guard side > 0, side <= Int.max / 4 else { return nil }
        let bytesPerRow = side * 4
        guard side <= Int.max / bytesPerRow else { return nil }
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buffer = context.data else { return nil }
        let rgba = buffer.bindMemory(to: UInt8.self, capacity: side * bytesPerRow)

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

    /// 截图 OCR（T11）：.accurate 档，中英双语。同步返回全文拼接；
    /// 解码失败或无文本返回 nil（调用方落"待定"）。
    /// 协议刻意不加该方法——截图管线经注入闭包使用，Core 不感知。
    static func readTextSync(imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        guard (try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])) != nil,
              let observations = request.results else {
            return nil
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
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

    /// CGImage 便捷入口（生产装配用）：解码 → 提取向量。
    static func extractVectorFromCGImage(_ cgImage: CGImage) throws -> [Double] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw VisionAnalysisError.noObservation
        }
        return try extractVector(observation)
    }

    /// VNFeaturePrintObservation → [Double]。公开 API 无逐元素访问器，
    /// 标准做法是从 data 缓冲按 elementType 整块拷贝
    /// （float=4 字节/元素，double=8 字节/元素）。
    static func extractVector(_ observation: VNFeaturePrintObservation) throws -> [Double] {
        let count = observation.elementCount
        guard count > 0 else { throw VisionAnalysisError.emptyFeaturePrint }
        let data = observation.data
        let elementSize: Int
        switch observation.elementType {
        case .float:
            elementSize = MemoryLayout<Float>.size
        case .double:
            elementSize = MemoryLayout<Double>.size
        default:
            throw VisionAnalysisError.unsupportedElementType
        }
        guard elementSize > 0, count <= Int.max / elementSize,
              data.count == count * elementSize else {
            throw VisionAnalysisError.emptyFeaturePrint
        }
        let vector: [Double]
        switch observation.elementType {
        case .float:
            vector = data.withUnsafeBytes { raw in
                let pointer = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                return UnsafeBufferPointer(start: pointer, count: count).map(Double.init)
            }
        case .double:
            vector = data.withUnsafeBytes { raw in
                let pointer = raw.baseAddress!.assumingMemoryBound(to: Double.self)
                return UnsafeBufferPointer(start: pointer, count: count).map { $0 }
            }
        default:
            throw VisionAnalysisError.unsupportedElementType
        }
        guard EmbeddingMath.isUsable(vector) else {
            throw VisionAnalysisError.emptyFeaturePrint
        }
        return vector
    }
}
