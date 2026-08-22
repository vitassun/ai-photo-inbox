// MARK: - LLMClientProtocol
// 职责：后端 LLM 兜底能力的协议抽象（tech-spec §2.2/§6 契约冻结）。
//       实现两套：RemoteLLMClient（走 backend）/ MockLLMClient（离线确定性），
//       外层 ResilientLLMClient 保证超时/失败一律回落纯规则结果。
// 任务卡：T13。

import Foundation

/// 分类结果值对象（与 screenshot_classifications 表词表一致）。
struct LLMClassification: Equatable, Codable {
    let category: String
    /// [0,1]。
    let confidence: Double
    /// 提取字段 JSON 字符串，无则 "{}"。
    let extractedFieldsJSON: String
    let suggestedAction: String
    /// [0,1]；≥0.9 UI 提示"高概率临时"。
    let temporaryLikelihood: Double
}

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
    func classifyScreenshot(ocrText: String) async throws -> LLMClassification
    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation
}

/// 运行模式：MOCK 为默认（$0 成本、离线可用）；LIVE 需要注入 token。
enum LLMMode {
    case mock
    case live
}
