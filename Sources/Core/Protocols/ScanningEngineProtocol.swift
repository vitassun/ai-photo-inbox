// MARK: - ScanningEngineProtocol
// 职责：扫描流水线驱动器的抽象（tech-spec §2.2 冻结签名）。
//       ViewModel 只依赖本协议；真实现见 Infrastructure/ScanningEngine。
// 任务卡：T03。

import Foundation

protocol ScanningEngineProtocol {
    /// 启动/续跑全库扫描。progress 在工作队列上同步回调（UI 方自行切主线程）。
    func runFullScan(progress: @escaping (ScanPhase, Double) -> Void)
    /// 暂停（在当前资产粒度生效）。
    func pause()
    /// 从暂停处续跑。
    func resume()
    var state: ScanPhase { get }
}
