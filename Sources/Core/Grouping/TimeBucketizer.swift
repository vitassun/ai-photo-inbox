// MARK: - TimeBucketizer
// 职责：按拍摄时间间隔把资产分桶（时间相近 ≈ 大概率同场景连拍）。
//       纯函数：不碰时钟、不碰 PhotoKit，输入输出全是值类型。
// 任务卡：T04（分组算法 V1：时间分桶，是 pHash/featureprint 精比的前置）。

import Foundation

enum TimeBucketizer {
    /// 将 (id, 拍摄时间) 列表按时间间隔分桶。
    ///
    /// 规则：先按时间升序排序；相邻两个时间点间隔 **严格大于** gapThreshold 秒才切开
    /// （恰好等于阈值视为同桶）。跨天本身不切桶——只看间隔大小。
    ///
    /// - Parameters:
    ///   - entries: 任意顺序的 (id, date) 列表。
    ///   - gapThreshold: 分桶间隔阈值，默认 1800 秒（30 分钟）。
    /// - Returns: 每桶为 id 数组；桶间按时间先后排列，桶内按时间升序。
    ///   空输入返回空数组。
    static func bucketize(
        _ entries: [(id: String, date: Date)],
        gapThreshold: TimeInterval = 1800
    ) -> [[String]] {
        guard !entries.isEmpty else { return [] }

        // 同一时间戳用 id 打破平局；Swift sort 不保证等值元素稳定，
        // 不加 tie-break 会让候选组顺序随输入顺序漂移。
        let sorted = entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        guard gapThreshold.isFinite, gapThreshold >= 0 else {
            // 无效阈值不能把整库错误合并进一个桶；保守地逐项隔离。
            return sorted.map { [$0.id] }
        }
        var buckets: [[String]] = []
        var currentBucket: [String] = [sorted[0].id]
        var previousDate = sorted[0].date

        for entry in sorted.dropFirst() {
            if entry.date.timeIntervalSince(previousDate) > gapThreshold {
                buckets.append(currentBucket)
                currentBucket = [entry.id]
            } else {
                currentBucket.append(entry.id)
            }
            previousDate = entry.date
        }
        buckets.append(currentBucket)
        return buckets
    }
}
