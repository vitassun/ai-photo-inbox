// MARK: - SystemPhotoLibraryService
// 职责：PhotoLibraryServiceProtocol 的 PhotoKit 真实现。V1 骨架期全部为 TODO 占位。
// 任务卡：T02（授权与元数据拉取）、T08（安全删除流）。
//
// 实现红线（T08 验收标准）：
//   删除只能走 PHPhotoLibrary.shared().performChanges +
//   PHAssetChangeRequest.deleteAssets —— 系统强制弹确认框，用户逐次批准。
//   本文件永远不允许出现任何绕过确认框的删除路径。

import Photos

final class SystemPhotoLibraryService: PhotoLibraryServiceProtocol {

    var authorizationStatus: PhotoAuthorizationStatus {
        // TODO(T02): 映射 PHPhotoLibrary.authorizationStatus(for: .readWrite)
        //   .notDetermined/.restricted/.denied/.authorized/.limited → 自家枚举。
        fatalError("TODO(T02): 见任务卡 T02")
    }

    func requestAccess(_ completion: @escaping (PhotoAuthorizationStatus) -> Void) {
        // TODO(T02): PHPhotoLibrary.requestAuthorization(for: .readWrite)，
        //   回调切主线程后再透传映射结果；limited 状态要引导用户升级权限。
        fatalError("TODO(T02): 见任务卡 T02")
    }

    func fetchAllAssets() -> [AssetRecord] {
        // TODO(T02): PHAsset.fetchAssets(with:) 遍历 → AssetRecord 映射；
        //   favorite=PHAsset.isFavorite, isEdited=PHAsset.adjustments.isNotEmpty（或 hasAdjustments）,
        //   isScreenshot=mediaSubtypes.contains(.photoScreenshot), creationDate 为 nil 时回退 modificationDate。
        fatalError("TODO(T02): 见任务卡 T02")
    }

    func fetchAssets(matching identifiers: [String]) -> [AssetRecord] {
        // TODO(T02): PHAsset.fetchAssets(withLocalIdentifiers:options:)，未知 id 忽略。
        fatalError("TODO(T02): 见任务卡 T02")
    }

    func requestDelete(
        of identifiers: [String],
        completion: @escaping (Bool, Error?) -> Void
    ) {
        // TODO(T08): PHPhotoLibrary.shared().performChanges {
        //   PHAssetChangeRequest.deleteAssets(assets as NSArray)
        // } —— 系统确认框是产品红线的一部分，不是障碍。
        // 调用方必须已过 SafetyRules 过滤；本方法不做二次红线校验（职责在 Core 层）。
        fatalError("TODO(T08): 见任务卡 T08")
    }
}
