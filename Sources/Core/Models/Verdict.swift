// MARK: - Verdict
// 职责：对单个资产的最终裁决结论（评分预选 + LLM 复核 + 用户确认后的落点）。
// 任务卡：T09（LLM 裁决 JSON 解析）/ T06。

import Foundation

/// keep=保留；delete=进入待删清单（仍需系统确认框）；archive=移入归档相册；todo=待用户决定。
enum Verdict: String, Codable, Equatable {
    case keep
    case delete
    case archive
    case todo
}
