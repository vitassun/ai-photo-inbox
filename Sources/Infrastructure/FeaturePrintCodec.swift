// MARK: - FeaturePrintCodec
// 职责：featureprints 表 data 列的编解码信封——首字节为类型标记，
//       使哈希（hex 字符串）与 embedding（double 数组）共存一张表且可辨。
// 任务卡：T05。表结构以 tech-spec §4 DDL 为权威，不加列、不加表。

import Foundation

enum FeaturePrintCodec {

    enum Kind: UInt8 {
        case hash = 1
        case embedding = 2
        /// 四维特征分数（clarity/aesthetics/faceQuality/saliency，已归一化）。
        case scores = 3
    }

    // MARK: pHash（"1" + utf8 hex）

    static func encodeHash(_ hex: String) -> Data {
        var data = Data([Kind.hash.rawValue])
        data.append(Data(hex.utf8))
        return data
    }

    static func decodeHash(_ data: Data) -> String? {
        guard let kind = data.first, kind == Kind.hash.rawValue else { return nil }
        return String(data: data.dropFirst(), encoding: .utf8)
    }

    // MARK: embedding（"2" + little-endian double 序列）

    static func encodeEmbedding(_ vector: [Double]) -> Data {
        var data = Data([Kind.embedding.rawValue])
        for value in vector {
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: littleEndianBits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeEmbedding(_ data: Data) -> [Double]? {
        guard let kind = data.first, kind == Kind.embedding.rawValue else { return nil }
        return decodeDoubles(data)
    }

    // MARK: 四维分数（"3" + little-endian double ×4，复用 embedding 编码）

    static func encodeScores(_ scores: [Double]) -> Data {
        var data = Data([Kind.scores.rawValue])
        for value in scores {
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: littleEndianBits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeScores(_ data: Data) -> [Double]? {
        guard let kind = data.first, kind == Kind.scores.rawValue else { return nil }
        return decodeDoubles(data)
    }

    private static func decodeDoubles(_ data: Data) -> [Double]? {
        let payload = data.dropFirst()
        let elementSize = MemoryLayout<Double>.size
        guard !payload.isEmpty, payload.count % elementSize == 0 else { return nil }
        var vector: [Double] = []
        vector.reserveCapacity(payload.count / elementSize)
        payload.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: payload.count, by: elementSize) {
                var bits: UInt64 = 0
                for byteIndex in 0..<elementSize {
                    bits |= UInt64(base[offset + byteIndex]) << (8 * byteIndex)
                }
                vector.append(Double(bitPattern: UInt64(littleEndian: bits)))
            }
        }
        return vector
    }
}
