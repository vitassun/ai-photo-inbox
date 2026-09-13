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

import AVFoundation   // 视频可用性探测返回 AVAsset
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
    /// 原件是否在本机。未知状态不会计入可释放空间。
    let localAvailability: AssetLocalAvailability
    /// Legacy boolean retained for source compatibility with test fixtures.
    let locallyAvailable: Bool
    /// 拍摄地坐标（度）；资产无 GPS 信息时为 nil。仅扫描当轮内存使用，不落库。
    let latitude: Double?
    let longitude: Double?

    init(
        localIdentifier: String,
        favorite: Bool,
        isEdited: Bool,
        mediaTypeRaw: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double,
        creationDate: Date?,
        modificationDate: Date?,
        isScreenshot: Bool,
        isLivePhoto: Bool,
        locallyAvailable: Bool = true,
        latitude: Double?,
        longitude: Double?,
        localAvailability: AssetLocalAvailability? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.favorite = favorite
        self.isEdited = isEdited
        self.mediaTypeRaw = mediaTypeRaw
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isScreenshot = isScreenshot
        self.isLivePhoto = isLivePhoto
        self.localAvailability = localAvailability
            ?? (locallyAvailable ? .available : .notDownloaded)
        self.locallyAvailable = locallyAvailable
        self.latitude = latitude
        self.longitude = longitude
    }

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
            modificationDate: modificationDate,
            isScreenshot: isScreenshot,
            isLivePhoto: isLivePhoto,
            latitude: safeLatitude,
            longitude: safeLongitude,
            localAvailability: localAvailability
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
        let availability = Self.localAvailability(of: phAsset)
        localAvailability = availability
        locallyAvailable = availability == .available
        if let coordinate = phAsset.location?.coordinate {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        } else {
            latitude = nil
            longitude = nil
        }
    }

    /// 无网络可用性探测的唯一入口。
    ///
    /// 契约（T17 补充验收）：
    /// - 必须在**后台线程**调用，因为底层 PhotoKit 请求是同步等待的；
    ///   主线程直接返回 `.unknown`，绝不阻塞 UI。
    /// - `isNetworkAccessAllowed = false` 是硬约束：探测不得触发下载。
    /// - 返回三态：`.available` / `.notDownloaded` / `.unknown`。
    ///   `.unknown` **不等于**未下载——调用方必须分别展示（见 AssetLocalAvailability 注释）。
    ///
    /// 图像走 fastFormat 缩略图请求；视频走 AVAsset 资源请求，避免全库枚举时
    /// 逐项解码视频。两者都用 info 字典区分「iCloud 未命中」与「本机已交付」。
    static func localAvailability(of asset: PHAsset) -> AssetLocalAvailability {
        guard !Thread.isMainThread else { return .unknown }
        switch asset.mediaType {
        case .image:
            return imageAvailability(of: asset)
        case .video:
            return videoAvailability(of: asset)
        default:
            return .unknown
        }
    }

    /// 图像：1×1 fastFormat 探测。info 里 PHImageResultIsInCloudKey 为 true
    /// 说明原件只在 iCloud；拿到图像则说明本机有可解码数据。
    private static func imageAvailability(of asset: PHAsset) -> AssetLocalAvailability {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        var result: AssetLocalAvailability = .unknown
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1, height: 1),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                result = .notDownloaded
            } else if image != nil {
                result = .available
            }
        }
        return result
    }

    /// 视频：用资源请求做本地媒体探测。
    ///
    /// 为什么用 lowQualityFormat 而非 highQuality：探测只回答「本机有没有原件」，
    /// 不需要高画质转码，低质量即可让 PhotoKit 命中本机已有资源而不额外生成。
    /// `isNetworkAccessAllowed = false` 是硬约束——iCloud 未下载的资产不会因此
    /// 被拉下来，只会回 PHImageResultIsInCloudKey = true。
    /// 拿不到结论时返回 `.unknown` 而非猜测未下载：未知状态不得计入可释放空间。
    private static func videoAvailability(of asset: PHAsset) -> AssetLocalAvailability {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        options.version = .current
        var result: AssetLocalAvailability = .unknown
        let semaphore = DispatchSemaphore(value: 0)
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
            if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                result = .notDownloaded
            } else if avAsset != nil {
                result = .available
            }
            semaphore.signal()
        }
        // 关闭网络时 PhotoKit 仍可能异步回调；设上限避免拖住扫描批次。
        // 超时即保持 .unknown——宁可显示未知，也不谎报未下载。
        _ = semaphore.wait(timeout: .now() + 2)
        return result
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

    /// 重新探测本机可用性。整批移到全局后台队列执行——探测内部是同步等待的
    /// PhotoKit 请求，放在调用线程会阻塞 UI。探测全程关闭网络，不触发下载。
    func probeLocalAvailability(
        of identifiers: [String],
        completion: @escaping ([String: AssetLocalAvailability]) -> Void
    ) {
        var seen = Set<String>()
        let normalized = identifiers.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !normalized.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: AssetLocalAvailability] = [:]
            result.reserveCapacity(normalized.count)
            // 每项独立探测：单项抛错或超时不影响整批，缺失的 id 一律补 .unknown。
            for id in normalized {
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                guard let asset = fetch.firstObject else {
                    // 资产已不存在（可能已被删除）：不给结论，交由调用方按 id 消失处理。
                    continue
                }
                result[id] = PHAssetSnapshot.localAvailability(of: asset)
            }
            for id in normalized where result[id] == nil {
                result[id] = .unknown
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func requestDelete(
        of identifiers: [String],
        completion: @escaping (Bool, Error?) -> Void
    ) {
        requestDeleteDetailed(of: identifiers) { result in
            let error: Error?
            if let failed = result.batches.first(where: { $0.status == .failed || $0.status == .cancelled }) {
                error = DeletionError.changeRequestFailed(reason: failed.reason)
            } else {
                error = nil
            }
            completion(result.approvedIDs.count == identifiers.count, error)
        }
    }

    /// 提交**单批**删除并回传系统结果。
    ///
    /// 分批职责已上移到 DeletionCoordinator（T10 补充验收）：服务不再自行切批，
    /// 只提交调用方交来的这一批，避免服务内部循环导致"下一批提交前无法重新复核"。
    /// 为兼容旧调用点，若入参超过单批上限，仍按 DeletionFlow 切分但**逐批提交**，
    /// 首批失败即把后续批次标记为 skipped。
    func requestDeleteDetailed(
        of identifiers: [String],
        completion: @escaping (DeletionRequestResult) -> Void
    ) {
        var seen = Set<String>()
        let normalizedIdentifiers = identifiers.filter { id in
            !id.isEmpty && seen.insert(id).inserted
        }
        guard !normalizedIdentifiers.isEmpty else {
            DispatchQueue.main.async { completion(DeletionRequestResult(batches: [])) }
            return
        }
        // 唯一删除通道：performChanges + deleteAssets，系统弹确认框由用户逐次批准。
        // 超上限自动分批（T10），按批顺序执行；任一批失败（含用户取消确认框）
        // 即停止后续批次——续传语义：调用方以 fetchAssets(matching:) 重查
        // 幸存者后重试，已删者自然消失。
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [DeletionBatchResult] = []
            var shouldContinue = true
            for (index, batch) in DeletionFlow.batches(of: normalizedIdentifiers).enumerated() {
                guard shouldContinue else {
                    results.append(DeletionBatchResult(
                        batchIndex: index,
                        requestedIDs: batch,
                        approvedIDs: [],
                        status: .skipped,
                        reason: "前一批次未完成"
                    ))
                    continue
                }

                let result: DeletionBatchResult = {
                let semaphore = DispatchSemaphore(value: 0)
                var batchResult: DeletionBatchResult?
                var submittedIDs: [String] = []

                PHPhotoLibrary.shared().performChanges {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
                    let objects = assets.objects(at: IndexSet(integersIn: 0..<assets.count))
                    if objects.isEmpty {
                        batchResult = DeletionBatchResult(
                            batchIndex: index,
                            requestedIDs: batch,
                            approvedIDs: [],
                            status: .skipped,
                            reason: "资产已不存在"
                        )
                    } else {
                        submittedIDs = objects.map(\.localIdentifier)
                        PHAssetChangeRequest.deleteAssets(objects as NSArray)
                    }
                } completionHandler: { success, changeError in
                    if batchResult == nil {
                        if success {
                            batchResult = DeletionBatchResult(
                                batchIndex: index,
                                requestedIDs: batch,
                                approvedIDs: submittedIDs,
                                status: .approved,
                                reason: nil
                            )
                        } else {
                            let nsError = changeError as NSError?
                            let cancelled = nsError?.domain == "PHPhotosErrorDomain"
                                && nsError?.code == 3072
                            batchResult = DeletionBatchResult(
                                batchIndex: index,
                                requestedIDs: batch,
                                approvedIDs: [],
                                status: cancelled ? .cancelled : .failed,
                                reason: changeError?.localizedDescription ?? "系统删除确认失败"
                            )
                        }
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                return batchResult ?? DeletionBatchResult(
                    batchIndex: index,
                    requestedIDs: batch,
                    approvedIDs: [],
                    status: .failed,
                    reason: "系统删除结果缺失"
                )
                }()

                results.append(result)
                shouldContinue = result.status == .approved
            }

            DispatchQueue.main.async {
                completion(DeletionRequestResult(batches: results))
            }
        }
    }

    enum DeletionError: Error {
        case changeRequestFailed(reason: String?)
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
        var seen = Set<String>()
        var records: [AssetRecord] = []
        records.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard let record = snapshot.makeAssetRecord(),
                  seen.insert(record.localIdentifier).inserted else { continue }
            records.append(record)
        }
        return records
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
