// MARK: - CandidateGrouper
// 职责：候选组构建——时间桶 × 地理簇 × pHash 粗筛三级相交，产出
//       CandidateGroup 供 T05 embedding 精比与 T09 评分消费。
//       纯函数：输入全是值类型，不碰 PhotoKit / 数据库 / 时钟。
// 任务卡：T04/T05。禁止全局两两比较：比较只发生在 (时间桶 × 地理簇) 内部。

import Foundation

/// 一个 (时间桶 × 地理单元) 切片：粗筛与精比共用的比较范围。
struct GroupingUnit {
    let bucketIndex: Int
    /// 单元内成员，按拍摄时间升序。
    let members: [AssetRecord]
}

enum CandidateGrouper {

    /// 分组规则：
    ///   1. creationDate 为 nil 的资产不参与（分桶前置过滤语义）。
    ///   2. 时间分桶：间隔 > AppConfig.timeGapThreshold 切开。
    ///   3. 桶内地理切分：有坐标者按半径聚簇；无坐标者共享一个"未知位置"
    ///      单元（截图天然无 EXIF GPS——可行性 §2.3，不能因此排除出粗筛；
    ///      pHash 门限仍防止误聚，且比较范围仍被时间桶切小，未触
    ///      "禁止全局两两比较"边界）。
    ///   4. (时间桶 × 地理单元) 内做 pHash 并查集：汉明距离 ≤ 阈值互连。
    ///      无哈希的成员自成单例（留给 T05 embedding 路线）。
    ///   5. 只有 ≥2 成员的连通分量成为 CandidateGroup；单例不成组。
    static func groups(
        from records: [AssetRecord],
        hashByID: [String: String]
    ) -> [CandidateGroup] {
        var groups: [CandidateGroup] = []
        for unit in timeGeoUnits(from: records) {
            for component in hammingComponents(unit.members, hashByID: hashByID)
            where component.count >= 2 {
                groups.append(
                    CandidateGroup(
                        id: "cand-\(unit.bucketIndex)-\(component[0].localIdentifier)",
                        members: component,
                        reason: "时间×地理×pHash"
                    )
                )
            }
        }
        return groups
    }

    /// 时间桶 × 地理单元切分（T04 粗筛与 T05 精比聚类共用的前置；
    /// 全局两两比较的禁令以本函数的输出范围为准）。确定性输出。
    static func timeGeoUnits(from records: [AssetRecord]) -> [GroupingUnit] {
        let dated = records.filter { $0.creationDate != nil }
        guard !dated.isEmpty else { return [] }

        let entries = dated.map { (id: $0.localIdentifier, date: $0.creationDate!) }
        let timeBuckets = TimeBucketizer.bucketize(entries, gapThreshold: AppConfig.timeGapThreshold)
        let recordByID = Dictionary(dated.map { ($0.localIdentifier, $0) },
                                    uniquingKeysWith: { first, _ in first })

        var units: [GroupingUnit] = []
        for (bucketIndex, bucket) in timeBuckets.enumerated() {
            let members = bucket.compactMap { recordByID[$0] }

            // 桶内地理切分。
            var geoUnits: [[AssetRecord]] = []
            var unknownLocation: [AssetRecord] = []
            var pendingCoords: [GeoPoint] = []
            for member in members {
                if let lat = member.latitude, let lon = member.longitude {
                    pendingCoords.append(GeoPoint(id: member.localIdentifier, latitude: lat, longitude: lon))
                } else {
                    unknownLocation.append(member)
                }
            }
            if !unknownLocation.isEmpty {
                geoUnits.append(unknownLocation)
            }
            for clusterIDs in GeoClusterer.cluster(pendingCoords) {
                let ids = Set(clusterIDs)
                geoUnits.append(members.filter { ids.contains($0.localIdentifier) })
            }

            for unit in geoUnits {
                units.append(GroupingUnit(bucketIndex: bucketIndex, members: unit))
            }
        }
        return units
    }

    /// 单元内按哈希汉明距离做并查集；无哈希成员自成单例。
    /// 返回的每个分量按时间升序（输入顺序）排列。
    private static func hammingComponents(
        _ unit: [AssetRecord],
        hashByID: [String: String]
    ) -> [[AssetRecord]] {
        let count = unit.count
        guard count > 0 else { return [] }

        var parent = Array(0..<count)
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

        for i in 0..<count {
            guard let hashI = hashByID[unit[i].localIdentifier] else { continue }
            for j in (i + 1)..<count {
                guard let hashJ = hashByID[unit[j].localIdentifier],
                      let distance = HashDistance.hamming(hexA: hashI, hexB: hashJ),
                      distance <= AppConfig.pHashDuplicateHammingDistance else { continue }
                let rootI = find(i)
                let rootJ = find(j)
                if rootI != rootJ { parent[rootJ] = rootI }
            }
        }

        var componentsByID: [Int: [AssetRecord]] = [:]
        var componentOrder: [Int] = []
        for (index, record) in unit.enumerated() {
            let root = find(index)
            if componentsByID[root] == nil {
                componentsByID[root] = []
                componentOrder.append(root)
            }
            componentsByID[root]?.append(record)
        }
        return componentOrder.compactMap { componentsByID[$0] }
    }
}
