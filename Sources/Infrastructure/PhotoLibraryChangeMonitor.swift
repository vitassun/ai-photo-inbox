// MARK: - PhotoLibraryChangeMonitor
// 职责：把 PHPhotoLibraryChangeObserver 回调翻译成自家事件（主线程投递），
//       供 T14 Daily Inbox 增量刷新消费。
// 任务卡：T02。生命周期：start 后必须 stop（注销监听并释放基准结果，防泄漏）。
//
// 并发模型：photoLibraryDidChange 在 PhotoKit 私有后台队列回调，而
// start()/stop() 由调用方任意线程触发——observedResult 的全部读写
// 收敛到一条私有串行队列，杜绝数据竞争。

import Photos

final class PhotoLibraryChangeMonitor: NSObject, PHPhotoLibraryChangeObserver {

    /// 事件接收方（弱引用；通常为 ViewModel 或扫描引擎）。
    weak var delegate: PhotoLibraryChangeObserving?

    /// 自持一份全库 fetch result 作为 diff 基准——
    /// PhotoKit 要求监听方持有 fetch result 引用，否则拿不到变更明细。
    /// 仅允许在 stateQueue 上读写。
    private var observedResult: PHFetchResult<PHAsset>?

    private let stateQueue = DispatchQueue(label: "com.aiphotoinbox.PhotoLibraryChangeMonitor.state")

    func start() {
        stateQueue.sync {
            guard observedResult == nil else { return }
            observedResult = PHAsset.fetchAssets(with: nil)
            PHPhotoLibrary.shared().register(self)
        }
    }

    func stop() {
        var needUnregister = false
        stateQueue.sync {
            needUnregister = (observedResult != nil)
            observedResult = nil
        }
        // register/unregister 必须成对；未 start 过的 stop 不触碰 PhotoKit。
        if needUnregister {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // PhotoKit 在任意后台队列回调：在 stateQueue 上取一致性快照，
    // 主线程投递放在最后一步。
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let event: PhotoLibraryChangeEvent? = stateQueue.sync { () -> PhotoLibraryChangeEvent? in
            guard let result = observedResult,
                  let details = changeInstance.changeDetails(for: result) else { return nil }

            let inserted = details.insertedObjects.map(\.localIdentifier)
            let removed = details.removedObjects.map(\.localIdentifier)
            // changedObjects 与 removedObjects 理论上互斥；防御性再排除一次已删除者。
            let removedSet = Set(removed)
            let updated = details.changedObjects
                .map(\.localIdentifier)
                .filter { !removedSet.contains($0) }

            // 以变更后的结果作为下一轮 diff 基准。
            observedResult = details.fetchResultAfterChanges

            return PhotoLibraryChangeEvent(
                insertedIdentifiers: inserted,
                updatedIdentifiers: updated,
                removedIdentifiers: removed
            )
        }
        guard let event else { return }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.photoLibraryDidChange(event)
        }
    }
}
