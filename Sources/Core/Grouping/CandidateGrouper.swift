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

    /// 一条"直接相似"关系：`a` 与 `b` 在同一个比较窗口内被判为相似。
    /// 关系是分组的唯一依据——窗口只负责限制**比较范围**，
    /// 不决定最终成员归属。
    struct SimilarityEdge: Equatable, Hashable {
        let a: String
        let b: String
        /// 归一化后的无向边（a < b），便于跨窗口去重。
        init(_ first: String, _ second: String) {
            if first <= second {
                a = first
                b = second
            } else {
                a = second
                b = first
            }
        }
    }

    /// 一次分组的结果：最终组 + 直接相似关系表。
    ///
    /// 拆开返回的原因：删除建议必须依赖**直接相似**的保留项，
    /// 而"连通"不等于"直接可替代"（A~B~C 里 A 不能替代 C）。
    /// 评分与替代校验复用 `edges`，不必再做两两比较。
    struct GroupingResult {
        var groups: [CandidateGroup]
        /// 无向直接相似边集合（a < b）。查询 O(1)。
        var edges: Set<SimilarityEdge>

        /// 两个资产之间是否存在直接相似关系。
        func isDirectlySimilar(_ first: String, _ second: String) -> Bool {
            edges.contains(SimilarityEdge(first, second))
        }

        /// 某个资产的直接相似邻居（用于替代校验与有界重算）。
        func neighbors(of id: String) -> Set<String> {
            var result = Set<String>()
            for edge in edges {
                if edge.a == id { result.insert(edge.b) }
                else if edge.b == id { result.insert(edge.a) }
            }
            return result
        }
    }

    /// 分组规则：
    ///   1. creationDate 缺失或非有限的资产不参与（分桶前置过滤语义）。
    ///   2. 时间分桶：间隔 > AppConfig.timeGapThreshold 切开。超过跨度/容量
    ///      上限时按**重叠窗口**切分（重叠只为不丢边界相似，见第 5 点）。
    ///   3. 桶内地理切分：有坐标者按半径聚簇；无坐标者共享一个"未知位置"
    ///      单元（截图天然无 EXIF GPS——可行性 §2.3，不能因此排除出粗筛；
    ///      pHash 门限仍防止误聚，且比较范围仍被时间桶切小，未触
    ///      "禁止全局两两比较"边界）。
    ///   4. 每个窗口内做 pHash 两两比较，命中的记为**直接相似边**。
    ///   5. 全部窗口比完后统一按资产 id 组装最终组：
    ///      - 窗口重叠会让同一对资产被比较两次，但边集合去重，
    ///        最终组按 id 归并 → 一个资产只属于一个最终候选组；
    ///      - 组 id 取成员中最小的 localIdentifier，与输入顺序无关，
    ///        打乱输入顺序结果完全一致。
    static func groups(
        from records: [AssetRecord],
        hashByID: [String: String]
    ) -> [CandidateGroup] {
        grouping(from: records, hashByID: hashByID).groups
    }

    /// 与 `groups(from:hashByID:)` 同源，额外返回直接相似边表供评分复用。
    static func grouping(
        from records: [AssetRecord],
        hashByID: [String: String]
    ) -> GroupingResult {
        // 跨窗口收集所有相似关系。比较范围仍被 (时间×地理×媒体类型×窗口)
        // 严格限制，没有全局两两比较。
        var edges: Set<SimilarityEdge> = []
        // 成员表：id → 记录。用于最后按 id 统一组装，避免依赖窗口切分方式。
        var recordByID: [String: AssetRecord] = [:]

        for unit in timeGeoUnits(from: records) {
            for record in unit.members {
                recordByID[record.localIdentifier] = record
            }
            collectEdges(in: unit.members, hashByID: hashByID, into: &edges)
        }

        let groups = assembleGroups(edges: edges, recordByID: recordByID)
        return GroupingResult(groups: groups, edges: edges)
    }

    /// 单元内两两比对并登记相似边。无哈希成员不产生边
    /// （留给 embedding 路线，见 `ScanningEngine.groupsIncludingEmbeddings`）。
    private static func collectEdges(
        in members: [AssetRecord],
        hashByID: [String: String],
        into edges: inout Set<SimilarityEdge>
    ) {
        let count = members.count
        guard count > 1 else { return }
        for i in 0..<count {
            let idI = members[i].localIdentifier
            guard let hashI = hashByID[idI] else { continue }
            for j in (i + 1)..<count {
                let idJ = members[j].localIdentifier
                guard let hashJ = hashByID[idJ],
                      let distance = HashDistance.hamming(hexA: hashI, hexB: hashJ),
                      distance <= AppConfig.pHashDuplicateHammingDistance else { continue }
                edges.insert(SimilarityEdge(idI, idJ))
            }
        }
    }

    /// 按资产 id 把所有相似边归并成最终候选组。
    ///
    /// 关键性质：
    /// - 传递连通（A~B、B~C → A、B、C 同组）：与并查集语义一致；
    /// - 一个资产只属于一个组：成员由 id 集合决定，且已做归属去重；
    /// - 确定性：组内按 id 排序，组间按最小 id 排序，组 id = 最小成员 id。
    private static func assembleGroups(
        edges: Set<SimilarityEdge>,
        recordByID: [String: AssetRecord]
    ) -> [CandidateGroup] {
        guard !edges.isEmpty else { return [] }

        // 并查集（按 id 字符串排序后索引化，保证确定性）。
        let ids = Set(edges.flatMap { [$0.a, $0.b] }).sorted()
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() { indexByID[id] = index }

        var parent = Array(0..<ids.count)
        func find(_ value: Int) -> Int {
            var root = value
            while parent[root] != root { root = parent[root] }
            var current = value
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        for edge in edges {
            guard let left = indexByID[edge.a], let right = indexByID[edge.b] else { continue }
            let rootLeft = find(left)
            let rootRight = find(right)
            if rootLeft != rootRight { parent[rootRight] = rootLeft }
        }

        var membersByRoot: [Int: [String]] = [:]
        for (index, id) in ids.enumerated() {
            membersByRoot[find(index), default: []].append(id)
        }

        // 每个 id 只出现一次（并查集天然保证），但仍显式去重以防将来改动回归。
        var claimed = Set<String>()
        var built: [CandidateGroup] = []
        // 只有 ≥2 成员的连通分量成组；单例不成组。
        for members in membersByRoot.values where members.count >= 2 {
            let uniqueMembers = members.filter { claimed.insert($0).inserted }
            guard uniqueMembers.count >= 2 else { continue }
            let ordered = uniqueMembers.sorted()
            let records = ordered.compactMap { recordByID[$0] }
            // 记录缺失（理论上不该发生，边只从 members 产生）：跳过而不是
            // 产出成员数与 id 数不一致的组，避免下游按 id/记录双口径错位。
            guard records.count == ordered.count else { continue }
            built.append(
                CandidateGroup(
                    id: "cand-\(ordered[0])",
                    members: records,
                    reason: "时间×地理×pHash"
                )
            )
        }
        // 组间按组 id 排序，保证输出顺序与输入顺序无关。
        return built.sorted { $0.id < $1.id }
    }

    /// 时间桶 × 地理单元切分（T04 粗筛与 T05 精比聚类共用的前置；
    /// 全局两两比较的禁令以本函数的输出范围为准）。确定性输出。
    static func timeGeoUnits(from records: [AssetRecord]) -> [GroupingUnit] {
        let dated = records.filter {
            guard let date = $0.creationDate else { return false }
            return date.timeIntervalSince1970.isFinite
        }
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
                if let lat = member.latitude, let lon = member.longitude,
                   lat.isFinite, lon.isFinite,
                   (-90...90).contains(lat), (-180...180).contains(lon) {
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

            // 不同媒体类型不能仅凭缩略图相似就互相替代（例如视频封面与照片）。
            // 在时间×地理单元内再按 mediaType 切分，保证 pHash 与 embedding 两条路径
            // 都不会跨媒体类型成组。
            for unit in geoUnits {
                let byMediaType = Dictionary(grouping: unit, by: { $0.mediaType.rawValue })
                for mediaType in byMediaType.keys.sorted() {
                    guard let members = byMediaType[mediaType], !members.isEmpty else { continue }
                    units.append(GroupingUnit(bucketIndex: bucketIndex, members: members))
                }
            }
        }
        return units
    }

    /// 单元内按哈希汉明距离做并查集；无哈希成员自成单例。
    /// 返回的每个分量按时间升序（输入顺序）排列。
    ///
    /// 说明：`groups(from:hashByID:)` 已改为"先收集相似边、再统一按 id 组装"，
    /// 不再需要每个窗口各出一套组。本函数保留为单窗口内的分量查询工具，
    /// 供需要的调用方（含测试）按窗口视角检查连通性。
    static func hammingComponents(
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
