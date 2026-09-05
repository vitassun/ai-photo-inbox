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
import PhotosUI   // presentLimitedLibraryPicker 所在框架
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
    /// 是否 Live Photo（.photoLive 子类型；删除须原子处理，见 T07/T10）。
    let isLivePhoto: Bool
    /// 原件是否在本机（T17：iCloud 未下载折叠分组依据）。
    let locallyAvailable: Bool
    /// 拍摄地坐标（度）；资产无 GPS 信息时为 nil。仅扫描当轮内存使用，不落库。
    let latitude: Double?
    let longitude: Double?

    /// 纯函数：快照 → AssetRecord。creationDate 为 nil 时回退 modificationDate
    /// （该回退策略全仓只允许出现在这一处，见任务卡 T02 边界）；
    /// localIdentifier 为空的资产剔除（防御 PhotoKit 异常数据）。
    func makeAssetRecord() -> AssetRecord? {
        guard !localIdentifier.isEmpty else { return nil }
        let mediaType = AssetMediaType(rawValue: mediaTypeRaw) ?? .unknown
        let safeDuration = mediaType == .video && duration.isFinite
            ? max(0, duration)
            : 0
        let safeLatitude: Double?
        let safeLongitude: Double?
        if let latitude, let longitude,
           latitude.isFinite, longitude.isFinite,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            safeLatitude = latitude
            safeLongitude = longitude
        } else {
            safeLatitude = nil
            safeLongitude = nil
        }
        return AssetRecord(
            localIdentifier: localIdentifier,
            favorite: favorite,
            isEdited: isEdited,
            mediaType: mediaType,
            pixelWidth: max(0, pixelWidth),
            pixelHeight: max(0, pixelHeight),
            duration: safeDuration,
            creationDate: creationDate ?? modificationDate,
            isScreenshot: isScreenshot,
            isLivePhoto: isLivePhoto,
            latitude: safeLatitude,
            longitude: safeLongitude,
            locallyAvailable: locallyAvailable
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
        isLivePhoto = phAsset.mediaSubtypes.contains(.photoLive)
        locallyAvailable = Self.isLocallyAvailable(phAsset)
        if let coordinate = phAsset.location?.coordinate {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        } else {
            latitude = nil
            longitude = nil
        }
    }

    /// 原件是否在本机（T17：iCloud 未下载折叠分组依据）。
    /// PHAsset 无公开"原件在本机"API（与 §1.4 文件大小同源的约束域）；
    /// 经 PHAssetResource 的运行时只读属性探测，任何异常一律保守回退
    /// "本机可用"——宁可少折叠，不可把可清理项误标成未下载而隐藏。
    /// 只读探测，无任何写入，不做体积读取（KVC 取 fileSize 的否决不适用）。
    private static func isLocallyAvailable(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return true }
        return resources.allSatisfy { resource in
            (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
        }
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
        guard !identifiers.isEmpty else {
            DispatchQueue.main.async { completion(true, nil) }
            return
        }
        // 唯一删除通道：performChanges + deleteAssets，系统弹确认框由用户逐次批准。
        // 超上限自动分批（T10），按批顺序执行；任一批失败（含用户取消确认框）
        // 即停止后续批次——续传语义：调用方以 fetchAssets(matching:) 重查
        // 幸存者后重试，已删者自然消失。
        DispatchQueue.global(qos: .userInitiated).async {
            let error = DeletionFlow.runBatches(identifiers) { batch, _ in
                let semaphore = DispatchSemaphore(value: 0)
                var batchError: Error?

                PHPhotoLibrary.shared().performChanges {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
                    let objects = assets.objects(at: IndexSet(integersIn: 0..<assets.count))
                    PHAssetChangeRequest.deleteAssets(objects as NSArray)
                } completionHandler: { success, changeError in
                    // 用户在确认框点取消 → success=false + PHPhotoLibraryError.userCancelled，
                    // 同样走失败路径：零删除发生、调用方可重试（T10 验收的拒绝路径）。
                    batchError = success ? nil : (changeError ?? DeletionError.changeRequestFailed)
                    semaphore.signal()
                }
                semaphore.wait()

                if let batchError {
                    throw batchError
                }
            }

            DispatchQueue.main.async {
                completion(error == nil, error)
            }
        }
    }

    enum DeletionError: Error {
        case changeRequestFailed
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
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    /// 跳转系统设置的本 App 页面（denied / limited 引导用）。
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
