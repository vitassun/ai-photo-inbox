// MARK: - PhotoLibraryServiceProtocol
// 职责：PhotoKit 能力的协议抽象（授权/元数据拉取/删除请求）。
//       纯逻辑层与 ViewModel 只依赖本协议；真实现见 Infrastructure/SystemPhotoLibraryService。
// 任务卡：T02（拉取）/ T10（删除流）。

import Foundation

/// 授权状态的自家枚举（映射 PHAuthorizationStatus，避免纯逻辑层 import Photos）。
enum PhotoAuthorizationStatus: Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    /// iOS 14+ 受限访问：只见用户选中的照片。
    case limited
}

enum DeletionBatchStatus: String, Codable, Equatable {
    case approved
    case cancelled
    case failed
    case skipped
}

/// 系统确认流的逐批结果。approvedIDs 只包含 PhotoKit 明确报告成功的 id；
/// 取消、失败和后续跳过批次绝不由 UI 通过“资产是否消失”反推。
struct DeletionBatchResult: Codable, Equatable {
    let batchIndex: Int
    let requestedIDs: [String]
    let approvedIDs: [String]
    let status: DeletionBatchStatus
    let reason: String?
}

struct DeletionRequestResult: Codable, Equatable {
    let batches: [DeletionBatchResult]

    var approvedIDs: [String] {
        batches.flatMap(\.approvedIDs)
    }

    var cancelled: Bool {
        batches.contains { $0.status == .cancelled }
    }

    var hasFailure: Bool {
        batches.contains { $0.status == .failed }
    }
}

protocol PhotoLibraryServiceProtocol {
    /// 当前相册访问授权状态（不触发弹窗）。
    var authorizationStatus: PhotoAuthorizationStatus { get }

    /// 请求相册访问授权，结果回调到主线程由实现方保证。
    func requestAccess(_ completion: @escaping (PhotoAuthorizationStatus) -> Void)

    /// 拉取全库资产元数据快照（只读元数据，绝不在此加载图像数据）。
    /// creationDate 为 nil 的资产由实现方决定剔除或回退 modificationDate。
    func fetchAllAssets() -> [AssetRecord]

    /// 按 localIdentifier 批量取快照（断点续扫时校准用）。未知 id 直接忽略。
    func fetchAssets(matching identifiers: [String]) -> [AssetRecord]

    /// 重新探测指定资产的本机可用性（T17 补充）。
    ///
    /// 契约：
    /// - **必须异步**，实现在后台线程执行探测，绝不在调用线程同步等待；
    ///   大媒体页的"重新探测"按钮依赖这一点不卡 UI。
    /// - **禁止联网**：探测不得触发 iCloud 下载。
    /// - 回调切主线程，返回 id → 三态可用性映射；未能得出结论的 id
    ///   应回传 `.unknown` 而非从字典中省略，以便页面明确区分"未知"与"未下载"。
    func probeLocalAvailability(
        of identifiers: [String],
        completion: @escaping ([String: AssetLocalAvailability]) -> Void
    )

    /// 发起删除请求。
    ///
    /// 红线（T10）：实现必须走 PHPhotoLibrary.performChanges +
    /// PHAssetChangeRequest.deleteAssets，让系统弹确认框由用户逐次批准；
    /// 本协议刻意不提供任何绕过系统确认的删除通道，review 时按此验收。
    func requestDelete(
        of identifiers: [String],
        completion: @escaping (_ success: Bool, _ error: Error?) -> Void
    )

    /// 带逐批结果的删除入口。默认实现兼容旧的协议假实现；PhotoKit 真实
    /// 实现必须覆盖它并返回 approved/cancelled/failed/skipped 的精确 id。
    func requestDeleteDetailed(
        of identifiers: [String],
        completion: @escaping (DeletionRequestResult) -> Void
    )
}

extension PhotoLibraryServiceProtocol {
    func requestDeleteDetailed(
        of identifiers: [String],
        completion: @escaping (DeletionRequestResult) -> Void
    ) {
        requestDelete(of: identifiers) { success, error in
            let status: DeletionBatchStatus = success ? .approved : .failed
            let batch = DeletionBatchResult(
                batchIndex: 0,
                requestedIDs: identifiers,
                approvedIDs: success ? identifiers : [],
                status: status,
                reason: error?.localizedDescription
            )
            completion(DeletionRequestResult(batches: [batch]))
        }
    }

    /// 默认实现：假实现与历史桩不需要真正探测，统一回传 `.unknown`。
    /// 注意 `.unknown` 不是"未下载"——调用方不得据此把资产归入未下载分组
    /// 或计入可释放空间。生产实现（SystemPhotoLibraryService）必须覆盖此方法。
    func probeLocalAvailability(
        of identifiers: [String],
        completion: @escaping ([String: AssetLocalAvailability]) -> Void
    ) {
        let unknown = Dictionary(
            uniqueKeysWithValues: identifiers.map { ($0, AssetLocalAvailability.unknown) }
        )
        DispatchQueue.main.async { completion(unknown) }
    }
}
