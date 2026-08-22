// MARK: - HashDistance
// 职责：十六进制感知哈希串的汉明距离。纯函数，供分桶内粗筛（T04）与
//       候选组构建消费；位运算实现在 Core 层，使分组逻辑零 Infrastructure 依赖。
// 任务卡：T04。

import Foundation

enum HashDistance {
    /// 两个等长十六进制哈希串的汉明距离——按解码后的哈希位计（每字符 4 bit），
    /// 不是字符编码字节差（否则阈值语义失真）。
    /// 长度不等、为空或含非法十六进制字符视为不可比，返回 nil。
    static func hamming(hexA: String, hexB: String) -> Int? {
        guard !hexA.isEmpty, hexA.count == hexB.count else { return nil }
        var distance = 0
        for (a, b) in zip(hexA.lowercased(), hexB.lowercased()) {
            guard let nibbleA = a.hexDigitValue, let nibbleB = b.hexDigitValue else {
                return nil
            }
            var differingBits = nibbleA ^ nibbleB
            while differingBits != 0 {
                distance += differingBits & 1
                differingBits >>= 1
            }
        }
        return distance
    }
}
