// MARK: - LLMClientProtocol
// 职责：后端 LLM 兜底能力的协议抽象（tech-spec §2.2/§6 契约冻结）。
//       实现包括 RemoteLLMClient（走 backend）、MockLLMClient（离线确定性结果）
//       与 ConsentGatedLLMClient（同意门闩 + 失败降级）。
// 任务卡：T13。

import Foundation

/// 分组解释请求条目（只传描述文本，绝不传原图——隐私红线 4）。
struct CandidateDescription: Equatable, Codable {
    let desc: String
}

/// 分组解释响应：仅展示用，不参与也不修改预选集合（SafetyRules 不受远端影响）。
struct BestShotExplanation: Equatable, Codable {
    let keepIndex: Int
    let reason: String
}

protocol LLMClientProtocol {
    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation
}

/// 运行模式：MOCK 为默认（$0 成本、离线可用）；LIVE 需要注入 token。
enum LLMMode {
    case mock
    case live
}
