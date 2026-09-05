// MARK: - PhotoLibraryChangeObserving
// 职责：相册增量变更的自家抽象（T02 封装 PHPhotoLibraryChangeObserver，
//       供 T14 Daily Inbox 增量刷新消费）。事件只含字符串 id，
//       纯逻辑层零 PhotoKit 依赖。
// 任务卡：T02。

import Foundation

/// 一次相册变更事件的增量快照（标识符均为 PHAsset.localIdentifier）。
struct PhotoLibraryChangeEvent: Equatable {
    /// 新出现的资产。
    let insertedIdentifiers: [String]
    /// 元数据被修改（收藏态/编辑态等）的资产；不含已删除者。
    let updatedIdentifiers: [String]
    /// 已从相册删除的资产。
    let removedIdentifiers: [String]
}

/// 相册变更监听协议。回调保证在主线程投递。
@MainActor
protocol PhotoLibraryChangeObserving: AnyObject {
    func photoLibraryDidChange(_ event: PhotoLibraryChangeEvent)
}
