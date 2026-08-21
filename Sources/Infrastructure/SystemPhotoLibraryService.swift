// MARK: - SystemPhotoLibraryService
// 职责：PhotoLibraryServiceProtocol 的 PhotoKit 真实现。
// 任务卡：T02（授权与元数据拉取）、T10（安全删除流）。
//
// 实现红线（T10 验收标准）：
//   删除只能走 PHPhotoLibrary.shared().performChanges +
//   PHAssetChangeRequest.deleteAssets —— 系统强制弹确认框，用户逐次批准。
//   本文件永远不允许出现任何绕过确认框的删除路径。
//
// 可测性设计：PHAsset 上的字段先一次性提取进 PHAssetSnapshot，
// 再经纯函数映射成 AssetRecord —— 映射逻辑不接触 PhotoKit 类型，
// CI 模拟器可全覆盖单测（含 creationDate 回退与未知 id 契约）。

import Photos
import UIKit

/// PHAsset 在扫描时刻的字段快照。只承载数据，不含行为；
/// 从 PHAsset 提取字段的唯一入口是 `init(phAsset:)`。
struct PHAssetSnapshot {
    let localIdentifier: String
    let favorite: Bool
    /// 用户是否编辑过。用 hasAdjustments 布尔标志：零额外 I/O，
    /// 适合 5 万张全量扫描；调整数据的实际读取属特征管线各卡，不在此层。
    let isEdited: Bool
    /// 与 AssetMediaType raw value 对齐（见 AssetRecord 注释）；未知值映射为 .unknown。
    let mediaTypeRaw: Int
    let pixelWidth: Int
    let pixelHeight: Int
    /// 视频时长（秒）；照片恒为 0。
    let duration: Double
    let creationDate: Date?
    let modificationDate: Date?
    let isScreenshot: Bool

    /// 纯函数：快照 → AssetRecord。creationDate 为 nil 时回退 modificationDate
    /// （该回退策略全仓只允许出现在这一处，见任务卡 T02 边界）；
    /// localIdentifier 为空的资产剔除（防御 PhotoKit 异常数据）。
    func makeAssetRecord() -> AssetRecord? {
        guard !localIdentifier.isEmpty else { return nil }
        return AssetRecord(
            localIdentifier: localIdentifier,
            favorite: favorite,
            isEdited: isEdited,
            mediaType: AssetMediaType(rawValue: mediaTypeRaw) ?? .unknown,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            creationDate: creationDate ?? modificationDate,
            isScreenshot: isScreenshot
        )
    }
}

extension PHAssetSnapshot {
    /// 从 PHAsset 提取字段。本类型中唯一允许接触 PhotoKit 实例的地方。
    init(phAsset: PHAsset) {
        localIdentifier = phAsset.localIdentifier
        favorite = phAsset.isFavorite
        isEdited = phAsset.hasAdjustments
        mediaTypeRaw = phAsset.mediaType.rawValue
        pixelWidth = phAsset.pixelWidth
        pixelHeight = phAsset.pixelHeight
        duration = phAsset.duration
        creationDate = phAsset.creationDate
        modificationDate = phAsset.modificationDate
        isScreenshot = phAsset.mediaSubtypes.contains(.photoScreenshot)
    }
}

final class SystemPhotoLibraryService: PhotoLibraryServiceProtocol {

    var authorizationStatus: PhotoAuthorizationStatus {
        Self.mapAuthorizationStatusRaw(
            PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
        )
    }

    func requestAccess(_ completion: @escaping (PhotoAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            // 协议契约：回调切主线程后透传映射结果。
            DispatchQueue.main.async {
                completion(SystemPhotoLibraryService.mapAuthorizationStatusRaw(status.rawValue))
            }
        }
    }

    func fetchAllAssets() -> [AssetRecord] {
        Self.assetRecords(from: Self.snapshots(in: PHAsset.fetchAssets(with: nil)))
    }

    func fetchAssets(matching identifiers: [String]) -> [AssetRecord] {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        return Self.assetRecords(from: Self.snapshots(in: fetch), matching: identifiers)
    }

    func requestDelete(
        of identifiers: [String],
        completion: @escaping (Bool, Error?) -> Void
    ) {
        // TODO(T10): PHPhotoLibrary.shared().performChanges {
        //   PHAssetChangeRequest.deleteAssets(assets as NSArray)
        // } —— 系统确认框是产品红线的一部分，不是障碍。
        // 调用方必须已过 SafetyRules 过滤；本方法不做二次红线校验（职责在 Core 层）。
        fatalError("TODO(T10): 见任务卡 T10")
    }

    // MARK: 纯函数层（CI 单测覆盖）

    /// 授权状态映射。入参用 raw Int 使本函数与测试文件都无需 import Photos；
    /// 数值为 PHAuthorizationStatus 冻结的枚举原值（iOS 14 起 limited=4，此后未变）。
    static func mapAuthorizationStatusRaw(_ raw: Int) -> PhotoAuthorizationStatus {
        switch raw {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .authorized
        case 4: return .limited
        default: return .notDetermined
        }
    }

    /// 纯函数：全量映射（剔除无 id 资产）。
    static func assetRecords(from snapshots: [PHAssetSnapshot]) -> [AssetRecord] {
        snapshots.compactMap { $0.makeAssetRecord() }
    }

    /// 纯函数：按请求 id 过滤并映射。调用方契约：未知 id 忽略不崩；
    /// 结果只含请求过的 id、按请求顺序输出且去重。
    static func assetRecords(
        from snapshots: [PHAssetSnapshot],
        matching identifiers: [String]
    ) -> [AssetRecord] {
        let byID = Dictionary(
            snapshots.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var records: [AssetRecord] = []
        records.reserveCapacity(identifiers.count)
        for id in identifiers where !seen.contains(id) {
            seen.insert(id)
            if let snapshot = byID[id], let record = snapshot.makeAssetRecord() {
                records.append(record)
            }
        }
        return records
    }

    private static func snapshots(in fetch: PHFetchResult<PHAsset>) -> [PHAssetSnapshot] {
        var result: [PHAssetSnapshot] = []
        result.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            result.append(PHAssetSnapshot(phAsset: asset))
        }
        return result
    }
}

// MARK: - Limited 权限辅助入口（T02：引导升级权限 / 管理所选照片）

extension SystemPhotoLibraryService {

    /// 弹出系统"管理所选照片"选择器。仅 limited 状态下响应，
    /// 且必须由用户主动触发的入口调用——不许自动弹出骚扰用户（T02 边界）。
    func presentLimitedLibraryPicker() {
        guard authorizationStatus == .limited else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    /// 跳转系统设置的本 App 页面（denied / limited 引导用）。
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
