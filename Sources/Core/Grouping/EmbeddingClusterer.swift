// MARK: - EmbeddingClusterer
// 职责：embedding 精比聚类——L2 归一化 + 阈值连通分量（union-find）。
//       纯函数、确定性（同输入同输出：按输入顺序遍历点对）。
// 任务卡：T05。禁止全局两两比较：调用方必须先经时间×地理单元切分。

import Foundation

enum EmbeddingMath {

    /// 只有有限、非零且维度非空的向量才可参与聚类。
    /// Vision/磁盘损坏产生的 NaN、无穷或零向量没有相似度语义，必须当作缺失特征。
    static func isUsable(_ vector: [Double]) -> Bool {
        guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else { return false }
        let normSquared = vector.reduce(0.0) { $0 + $1 * $1 }
        return normSquared.isFinite && normSquared > 0
    }

    /// L2 归一化到单位长度。零向量（无方向）原样返回。
    static func normalized(_ vector: [Double]) -> [Double] {
        guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else { return [] }
        let normSquared = vector.reduce(0.0) { $0 + $1 * $1 }
        guard normSquared.isFinite else { return [] }
        let norm = normSquared.squareRoot()
        guard norm > 0, norm.isFinite else { return vector }
        return vector.map { $0 / norm }
    }

    /// 欧氏距离；维度不等视为不可比。
    static func euclidean(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, isUsable(a), isUsable(b) else { return nil }
        var sum = 0.0
        for index in a.indices {
            let delta = a[index] - b[index]
            sum += delta * delta
        }
        guard sum.isFinite else { return nil }
        return sum.squareRoot()
    }
}

enum EmbeddingClusterer {

    /// 阈值连通分量：欧氏距离 ≤ threshold 的成员互连（传递闭包）。
    /// - Parameters:
    ///   - members: (id, vector) 列表；向量须已归一化（单位向量欧氏 ∈ [0,2]）。
    ///   - threshold: AppConfig.embeddingClusterDistanceThreshold。
    /// - Returns: 每个分量为 id 数组，按首成员输入顺序排列；单例分量也返回，
    ///   由调用方决定是否丢弃（候选组语义要求 ≥2 成员才成组）。
    static func components(
        of members: [(id: String, vector: [Double])],
        threshold: Double = AppConfig.embeddingClusterDistanceThreshold
    ) -> [[String]] {
        guard !members.isEmpty else { return [] }
        guard threshold.isFinite, threshold >= 0 else {
            return members.map { [$0.id] }
        }

        var parent = Array(0..<members.count)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var current = index
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        for i in 0..<members.count {
            for j in (i + 1)..<members.count {
                guard let distance = EmbeddingMath.euclidean(members[i].vector, members[j].vector),
                      distance <= threshold else { continue }
                let rootI = find(i)
                let rootJ = find(j)
                if rootI != rootJ { parent[rootJ] = rootI }
            }
        }

        var componentsByID: [Int: [String]] = [:]
        var componentOrder: [Int] = []
        for (index, member) in members.enumerated() {
            let root = find(index)
            if componentsByID[root] == nil {
                componentsByID[root] = []
                componentOrder.append(root)
            }
            componentsByID[root]?.append(member.id)
        }
        return componentOrder.compactMap { componentsByID[$0] }
    }
}
