// MARK: - BoundedConcurrencyRunner
// 职责：受控并发批处理——N 个任务以信号量限流并发执行，
//       全部完成后回调恰好一次。供 Vision 批量分析等场景使用。
// 任务卡：T08（并发调度验收：上限受控、完成计数精确不丢）。

import Foundation

enum BoundedConcurrencyRunner {

    /// 并发跑 itemCount 个任务。
    /// - Parameters:
    ///   - maxConcurrent: 同时在跑的任务数上限（≥1）。
    ///   - worker: 任务体；**必须恰好调用一次 done**（约定即契约）。
    ///   - onFinish: 全部任务的 done 都到齐后回调一次。
    static func run(
        itemCount: Int,
        maxConcurrent: Int,
        worker: @escaping (_ index: Int, _ done: @escaping () -> Void) -> Void,
        onFinish: @escaping () -> Void
    ) {
        precondition(maxConcurrent >= 1, "并发上限至少为 1")
        guard itemCount > 0 else {
            onFinish()
            return
        }

        let semaphore = DispatchSemaphore(value: maxConcurrent)
        let group = DispatchGroup()

        for index in 0..<itemCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                worker(index) {
                    semaphore.signal()
                    group.leave()
                }
            }
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated), execute: onFinish)
    }
}
