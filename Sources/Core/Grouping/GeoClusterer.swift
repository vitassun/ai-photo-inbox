// MARK: - GeoClusterer
// 职责：地理分桶——把带经纬度的资产按球面距离聚成簇（union-find）。
//       纯函数：只做几何计算，不碰 PhotoKit 与时钟。
// 任务卡：T04。复杂度 O(k²)，仅用于时间桶内（k 为桶内成员数，规模受控，
//       满足"禁止全局两两比较"边界——先时间分桶、后桶内地理聚类）。

import Foundation

/// 一个带地理坐标的分组输入点。
struct GeoPoint: Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
}

enum GeoClusterer {

    /// 半径聚类：任意两点球面距离 ≤ radiusMeters 即归同簇（传递闭包）。
    /// - Returns: 每簇为 id 数组，簇间按首成员在输入中的出现顺序排列，簇内同序。
    ///   空输入返回空数组。
    static func cluster(
        _ points: [GeoPoint],
        radiusMeters: Double = AppConfig.geoClusterRadiusMeters
    ) -> [[String]] {
        guard !points.isEmpty else { return [] }
        guard radiusMeters.isFinite, radiusMeters >= 0 else {
            return points.map { [$0.id] }
        }

        var parent = Array(0..<points.count)
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

        for i in 0..<points.count {
            for j in (i + 1)..<points.count where
                haversineMeters(points[i], points[j]) <= radiusMeters {
                let rootI = find(i)
                let rootJ = find(j)
                if rootI != rootJ { parent[rootJ] = rootI }
            }
        }

        var orderByRoot: [Int: [String]] = [:]
        var rootOrder: [Int] = []
        for (index, point) in points.enumerated() {
            let root = find(index)
            if orderByRoot[root] == nil {
                orderByRoot[root] = []
                rootOrder.append(root)
            }
            orderByRoot[root]?.append(point.id)
        }
        return rootOrder.compactMap { orderByRoot[$0] }
    }

    /// 球面距离（Haversine，地球平均半径 6371km）。
    static func haversineMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        guard a.latitude.isFinite, a.longitude.isFinite,
              b.latitude.isFinite, b.longitude.isFinite,
              (-90...90).contains(a.latitude), (-180...180).contains(a.longitude),
              (-90...90).contains(b.latitude), (-180...180).contains(b.longitude) else {
            return .greatestFiniteMagnitude
        }
        let earthRadius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * Double.pi / 180
        let dLon = (b.longitude - a.longitude) * Double.pi / 180
        let lat1 = a.latitude * Double.pi / 180
        let lat2 = b.latitude * Double.pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        // 浮点误差可能让 h 略超出 [0,1]；钳制避免 sqrt(1-h) 产生 NaN。
        let clampedH = max(0, min(1, h))
        return 2 * earthRadius * atan2(sqrt(clampedH), sqrt(1 - clampedH))
    }
}
