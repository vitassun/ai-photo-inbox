// MARK: - PerceptualHash
// 职责：自实现 pHash（DCT 感知哈希）。纯函数核心：灰度缓冲进，十六进制串出；
//       另提供从编码图像字节（JPEG/PNG）出发的便捷入口（ImageIO 解码）。
// 任务卡：T04。不引第三方库；朴素 O(N·k) DCT 在 32×32 规模下开销可忽略。

import Foundation
import CoreGraphics
import ImageIO

enum PerceptualHash {

    /// 降采样网格边长（pHash 惯例 32×32）。
    static let gridSize = 32
    /// 取左上角低频区边长（8×8 = 64 bit = 16 个十六进制字符）。
    static let lowFreqSize = 8

    // MARK: 纯函数核心

    /// 单通道灰度缓冲 → pHash 十六进制串。
    /// - Parameters:
    ///   - grayPixels: 行优先灰度值（0=黑，255=白），count 必须等于 width*height。
    static func hash(grayPixels: [UInt8], width: Int, height: Int) -> String? {
        guard width > 0, height > 0, width <= Int.max / height,
              grayPixels.count == width * height else { return nil }

        let matrix = downsampleToGrid(grayPixels, width: width, height: height)
        let dct = dct2(matrix)

        var values: [Double] = []
        values.reserveCapacity(lowFreqSize * lowFreqSize)
        for row in dct.prefix(lowFreqSize) {
            for cell in row.prefix(lowFreqSize) {
                values.append(cell)
            }
        }

        // pHash 的阈值应由 AC 低频分量决定；DC 分量代表整张图平均亮度，
        // 混入中位数会让整体变亮/变暗被误当成结构差异。
        let medianValues = Array(values.dropFirst())
        let sorted = medianValues.sorted()
        let middle = medianValues.count / 2
        let median = medianValues.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]

        var bits = ""
        bits.reserveCapacity(values.count)
        for value in values {
            bits.append(value > median ? "1" : "0")
        }
        return Self.bitsToHex(bits)
    }

    /// 编码图像字节（JPEG/PNG）→ pHash。解码失败返回 nil。
    static func hash(fromEncodedImageData data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return hash(cgImage: image)
    }

    /// CGImage → 固定 64×64 RGBA 绘制 → 逐像素亮度 → 纯函数核心。
    static func hash(cgImage: CGImage) -> String? {
        let side = 64
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
        var gray: [UInt8] = []
        gray.reserveCapacity(side * side)
        for pixel in 0..<(side * side) {
            let offset = pixel * 4
            // Keep each channel calculation separate. Swift 6.2 otherwise spends
            // excessive type-checking time on the nested arithmetic expression.
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            let weightedSum = 299 * red + 587 * green + 114 * blue
            let lumaValue = max(0, min(255, weightedSum / 1000))
            let luma = UInt8(lumaValue)
            gray.append(luma)
        }
        return hash(grayPixels: gray, width: side, height: side)
    }

    // MARK: 内部实现

    /// 区域均值降采样到 gridSize×gridSize 的归一化矩阵（0~1）。
    private static func downsampleToGrid(
        _ pixels: [UInt8], width: Int, height: Int
    ) -> [[Double]] {
        var grid = [[Double]]()
        grid.reserveCapacity(gridSize)
        for gy in 0..<gridSize {
            // 输入缩略图有时小于 32×32；把采样区间钳在图像边界内，
            // 避免小图在后段网格访问越界。
            let y0 = min(height - 1, gy * height / gridSize)
            let y1 = min(height, max(y0 + 1, (gy + 1) * height / gridSize))
            var row: [Double] = []
            row.reserveCapacity(gridSize)
            for gx in 0..<gridSize {
                let x0 = min(width - 1, gx * width / gridSize)
                let x1 = min(width, max(x0 + 1, (gx + 1) * width / gridSize))
                var sum = 0
                for y in y0..<y1 {
                    let base = y * width
                    for x in x0..<x1 {
                        sum += Int(pixels[base + x])
                    }
                }
                let count = (y1 - y0) * (x1 - x0)
                row.append(Double(sum) / Double(count) / 255.0)
            }
            grid.append(row)
        }
        return grid
    }

    /// 二维 DCT-II（行列分离两次一维变换）。
    private static func dct2(_ input: [[Double]]) -> [[Double]] {
        let rows = input.map { dct1($0) }
        guard !rows.isEmpty else { return [] }
        let n = rows[0].count
        var columns = [[Double]]()
        columns.reserveCapacity(n)
        for c in 0..<n {
            columns.append(dct1(rows.map { $0[c] }))
        }
        // 转回行主序：out[r][c] = columns[c][r]
        return (0..<rows.count).map { r in columns.map { $0[r] } }
    }

    /// 一维 DCT-II：X[k] = Σ x[n] · cos(π/N · (n+0.5) · k)。
    private static func dct1(_ vector: [Double]) -> [Double] {
        let n = vector.count
        guard n > 0 else { return [] }
        let factor = Double.pi / Double(n)
        var output = [Double](repeating: 0, count: n)
        for k in 0..<n {
            var sum = 0.0
            for sample in 0..<n {
                sum += vector[sample] * cos(factor * (Double(sample) + 0.5) * Double(k))
            }
            output[k] = sum
        }
        return output
    }

    /// 位串 → 十六进制串（每 4 位一个字符；位数非 4 倍数时低位补 0）。
    static func bitsToHex(_ bits: String) -> String {
        var padded = Substring(bits)
        var hex = ""
        while !padded.isEmpty {
            let chunk = padded.prefix(4)
            padded = padded.dropFirst(chunk.count)
            var value = 0
            for bit in chunk {
                value = value << 1 | (bit == "1" ? 1 : 0)
            }
            hex += String(value, radix: 16)
        }
        return hex
    }
}
