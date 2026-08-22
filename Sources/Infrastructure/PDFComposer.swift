// MARK: - PDFComposer
// 职责：多张收据截图本地合成单个 PDF（可分享）。纯 UIKit 渲染，
//       不出网、不自动分享（T12 边界：一切动作纯本地）。
// 任务卡：T12。

import Foundation
import UIKit

enum PDFComposer {

    enum ComposerError: Error {
        case noImages
        case imageDecodeFailed(index: Int)
    }

    /// 把若干图像字节按顺序合成 PDF，每图一页（页面尺寸 = 图像尺寸）。
    /// - Returns: PDF 字节流（非空、页数 = 图像张数）。
    static func compose(imageDatas: [Data]) throws -> Data {
        guard !imageDatas.isEmpty else { throw ComposerError.noImages }

        var decoded: [UIImage] = []
        for (index, data) in imageDatas.enumerated() {
            guard let image = UIImage(data: data) else {
                throw ComposerError.imageDecodeFailed(index: index)
            }
            decoded.append(image)
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "AI Photo Inbox",
        ]
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        return renderer.pdfData { context in
            for image in decoded {
                context.beginPage()
                // 等比缩放适配页面，留 24pt 边距。
                let margin: CGFloat = 24
                let available = CGSize(width: bounds.width - margin * 2, height: bounds.height - margin * 2)
                let scale = min(available.width / max(image.size.width, 1),
                                available.height / max(image.size.height, 1))
                let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let origin = CGPoint(x: (bounds.width - drawSize.width) / 2,
                                     y: (bounds.height - drawSize.height) / 2)
                image.draw(in: CGRect(origin: origin, size: drawSize))
            }
        }
    }

    /// 页数校验辅助：经 CGPDFDocument 解析页数。仅用于测试断言；生产路径不依赖它。
    static func pageCount(in pdfData: Data) -> Int {
        guard let provider = CGDataProvider(pdfData as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}
