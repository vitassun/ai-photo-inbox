// MARK: - ImageQualityDSP
// 职责：低质量检测的自实现 DSP——拉普拉斯方差清晰度、灰度直方图曝光分。
//       纯函数：字节缓冲进出，零图像框架类型（Core 层铁律）。
// 任务卡：T06。产出喂 KeepScore.Inputs 的 clarity/exposure 通道（权重校准属 T09）。

import Foundation

enum ImageQualityDSP {

    // MARK: 清晰度（拉普拉斯方差法）

    /// 清晰度得分：内部像素做四邻域拉普拉斯响应，方差经 AppConfig 尺度归一化到 0~1。
    /// 定义行为：宽或高 < 3（无内部像素）返回 0 分；缓冲与维度不符返回 nil。
    static func clarityScore(grayPixels: [UInt8], width: Int, height: Int) -> Double? {
        guard width > 0, height > 0, grayPixels.count == width * height else { return nil }
        guard width >= 3, height >= 3 else { return 0 }

        var responses = [Double]()
        responses.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Double(grayPixels[y * width + x])
                let left = Double(grayPixels[y * width + x - 1])
                let right = Double(grayPixels[y * width + x + 1])
                let up = Double(grayPixels[(y - 1) * width + x])
                let down = Double(grayPixels[(y + 1) * width + x])
                responses.append(left + right + up + down - 4 * center)
            }
        }

        let count = Double(responses.count)
        let mean = responses.reduce(0, +) / count
        let variance = responses.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        return min(1, max(0, variance / AppConfig.dspLaplacianNormalizationScale))
    }

    // MARK: 曝光（灰度直方图）

    /// 曝光质量分：1 −（过曝像素占比 + 欠曝像素占比），钳制 0~1。
    /// 全黑/全白图触底为 0；均匀中间调为 1。维度不符返回 nil。
    static func exposureScore(grayPixels: [UInt8], width: Int, height: Int) -> Double? {
        guard width > 0, height > 0, grayPixels.count == width * height else { return nil }
        guard !grayPixels.isEmpty else { return nil }

        var overExposed = 0
        var underExposed = 0
        for pixel in grayPixels {
            if pixel >= AppConfig.dspOverExposedLumaThreshold {
                overExposed += 1
            } else if pixel <= AppConfig.dspUnderExposedLumaThreshold {
                underExposed += 1
            }
        }
        let badRatio = Double(overExposed + underExposed) / Double(grayPixels.count)
        return min(1, max(0, 1 - badRatio))
    }

    // MARK: 灰度转换

    /// RGBA8 缓冲 → 单通道亮度（Rec.601）。输入长度不符返回 nil。
    /// 供特征管线把解码位图统一成 DSP 输入格式。
    static func lumaFromRGBA(rgbaBytes: [UInt8]) -> [UInt8]? {
        guard rgbaBytes.count % 4 == 0 else { return nil }
        var luma = [UInt8]()
        luma.reserveCapacity(rgbaBytes.count / 4)
        var index = 0
        while index < rgbaBytes.count {
            let value = (299 * Int(rgbaBytes[index])
                + 587 * Int(rgbaBytes[index + 1])
                + 114 * Int(rgbaBytes[index + 2])) / 1000
            luma.append(UInt8(max(0, min(255, value))))
            index += 4
        }
        return luma
    }
}
