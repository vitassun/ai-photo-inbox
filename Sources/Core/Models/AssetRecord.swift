// MARK: - AssetRecord
// 职责：相册资产的纯数据快照（不可变值类型）。纯逻辑层只认这个结构，
//       绝不 import Photos —— 分组/评分/安全规则因此可在 CI 模拟器上无真机测试。
// 任务卡：T02（Infrastructure 层负责从 PHAsset 填充此结构）。

import Foundation

/// 媒体类型。raw value 与 PHAssetMediaType 对齐，避免纯逻辑层 import Photos。
enum AssetMediaType: Int, Codable, Equatable {
    case unknown = 0
    case image = 1
    case video = 2
    case audio = 3
}

/// 一张照片/视频在扫描时刻的快照。
struct AssetRecord: Codable, Equatable {
    /// PHAsset.localIdentifier 原样透传；纯逻辑层只当不透明字符串用。
    let localIdentifier: String
    /// 用户是否在系统相册收藏过（红线：收藏永不预选删除，见 SafetyRules）。
    let favorite: Bool
    /// 是否被用户编辑过（红线：编辑过永不预选删除）。
    let isEdited: Bool
    let mediaType: AssetMediaType
    let pixelWidth: Int
    let pixelHeight: Int
    /// 视频时长（秒）；照片恒为 0。
    let duration: Double
    /// 拍摄/创建时间；PHAsset.creationDate 可能为 nil，分桶前由适配层过滤。
    let creationDate: Date?
    /// 是否截屏（截图是强删除候选信号之一）。
    let isScreenshot: Bool
    /// 是否 Live Photo（含配对视频组件，删除须原子处理，见 T07/T10）。
    let isLivePhoto: Bool
    /// 拍摄地纬度（度）；无 GPS 信息时为 nil。仅扫描当轮内存使用（分组），
    /// 资产表 DDL 无对应列、不落库（tech-spec §4 冻结）。
    let latitude: Double?
    /// 拍摄地经度（度）；无 GPS 信息时为 nil。
    let longitude: Double?
    /// 原件是否在本机（iCloud 未下载 = false）。T17 大媒体页折叠分组依据；
    /// assets 表同名列的内存来源，适配层从 PHAsset.locallyAvailable 填充。
    var locallyAvailable: Bool = true

    /// 像素总量，供低质量/大文件启发式参考。
    var pixelCount: Int {
        guard pixelWidth > 0, pixelHeight > 0 else { return 0 }
        let result = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        return result.overflow ? Int.max : result.partialValue
    }
}
