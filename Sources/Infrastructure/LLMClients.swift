// MARK: - RemoteLLMClient / MockLLMClient / ResilientLLMClient
// 职责：T13 LLM 兜底客户端三件套。
//   RemoteLLMClient  — URLSession 对接 backend 两端点（Bearer 鉴权、8s 超时、至多重试一次）；
//   MockLLMClient    — 离线确定性结果（MOCK 默认模式，$0 成本）；
//   ResilientLLMClient — 降级铁律执行者：任何失败回落纯规则结果，UI 永远可用。
// 任务卡：T13。token 绝不入 git/日志；不在主线程同步等待（async 全程后台）。

import Foundation

// MARK: 远端实现

final class RemoteLLMClient: LLMClientProtocol {

    enum LLMError: Error {
        case tokenMissing          // → 调用方自动转 MOCK/规则路径
        case httpStatus(Int)
        case malformedResponse
        case retriesExhausted
    }

    private let baseURL: URL
    private let tokenProvider: () -> String?
    private let session: URLSession

    /// - Parameters:
    ///   - tokenProvider: 每次请求时取 token（Keychain/构建注入）；nil 即无凭据。
    init(baseURL: URL, tokenProvider: @escaping () -> String?, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = AppConfig.llmTimeoutSeconds
            configuration.timeoutIntervalForResource = AppConfig.llmTimeoutSeconds
            self.session = URLSession(configuration: configuration)
        }
    }

    func classifyScreenshot(ocrText: String) async throws -> LLMClassification {
        // 契约 §6.1：{"ocr_text": "...", "hints": {...}}
        let body: [String: Any] = ["ocr_text": ocrText, "hints": [:]]
        let data = try await post(path: "/v1/screenshots/classify", body: body)
        return try Self.decodeClassification(data)
    }

    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
        // 契约 §6.2：{"candidates": [{"desc": "..."}, ...]}
        let payload = candidates.map { ["desc": $0.desc] }
        let data = try await post(path: "/v1/groups/explain", body: ["candidates": payload])
        return try Self.decodeExplanation(data)
    }

    // MARK: 传输（含至多一次重试）

    private func post(path: String, body: [String: Any]) async throws -> Data {
        guard let token = tokenProvider() else {
            throw LLMError.tokenMissing
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = LLMError.retriesExhausted
        for attempt in 0...AppConfig.llmMaxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.malformedResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw LLMError.httpStatus(http.statusCode)
                }
                return data
            } catch {
                lastError = error
                _ = attempt   // 重试策略：至多 AppConfig.llmMaxRetries 次，无退避（本地代理场景）
            }
        }
        throw lastError
    }

    // MARK: 解析（契约 §6.1/§6.2 snake_case 字段）

    static func decodeClassification(_ data: Data) throws -> LLMClassification {
        struct Wire: Decodable {
            let category: String
            let confidence: Double
            let extracted_fields: [String: String]?
            let suggested_action: String
            let temporary_likelihood: Double
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let fieldsJSON = wire.extracted_fields.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LLMClassification(
            category: wire.category,
            confidence: wire.confidence,
            extractedFieldsJSON: fieldsJSON,
            suggestedAction: wire.suggested_action,
            temporaryLikelihood: wire.temporary_likelihood
        )
    }

    static func decodeExplanation(_ data: Data) throws -> BestShotExplanation {
        struct Wire: Decodable {
            let keep_index: Int
            let reason: String
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return BestShotExplanation(keepIndex: wire.keep_index, reason: wire.reason)
    }
}

// MARK: 离线 MOCK 实现（默认模式）

/// 确定性结果：验证码类给临时标记建议；其余按词表首命中给 copy 建议；
/// 无信号给 other + manual_review——与规则分类器的保守口径一致。
final class MockLLMClient: LLMClientProtocol {

    func classifyScreenshot(ocrText: String) async throws -> LLMClassification {
        let lowered = ocrText.lowercased()
        if lowered.contains("验证码") || lowered.contains("verification code") {
            return LLMClassification(category: "verification_code", confidence: 0.8,
                                     extractedFieldsJSON: "{}",
                                     suggestedAction: "mark_temporary", temporaryLikelihood: 0.95)
        }
        if lowered.contains("快递") || lowered.contains("单号") || lowered.contains("运单") {
            return LLMClassification(category: "courier", confidence: 0.8,
                                     extractedFieldsJSON: "{}",
                                     suggestedAction: "extract_tracking", temporaryLikelihood: 0.85)
        }
        return LLMClassification(category: "other", confidence: 0.4,
                                 extractedFieldsJSON: "{}",
                                 suggestedAction: "manual_review", temporaryLikelihood: 0.5)
    }

    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
        BestShotExplanation(keepIndex: 0, reason: "MOCK：第 0 张综合特征最优（离线确定性结果）")
    }
}

// MARK: 弹性包装（降级铁律执行者）

/// 远端优先、失败回落纯规则的组合客户端。降级后的返回值与直接调用
/// 纯规则路径完全一致（等价断言见测试），UI 与 SafetyRules 不受远端影响。
final class ResilientLLMClient: LLMClientProtocol {

    private let remote: LLMClientProtocol
    /// 规则兜底闭包（生产处传 ScreenshotRuleClassifier.classify 的适配）。
    private let fallbackClassify: (String) -> ScreenshotVerdict
    private let isLiveMode: () -> Bool
    private let mock = MockLLMClient()

    init(remote: LLMClientProtocol,
         fallbackClassify: @escaping (String) -> ScreenshotVerdict,
         isLiveMode: @escaping () -> Bool) {
        self.remote = remote
        self.fallbackClassify = fallbackClassify
        self.isLiveMode = isLiveMode
    }

    func classifyScreenshot(ocrText: String) async throws -> LLMClassification {
        guard isLiveMode() else {
            return mock.classifyScreenshot(ocrText: ocrText)
        }
        do {
            return try await remote.classifyScreenshot(ocrText: ocrText)
        } catch {
            // 降级铁律：超时/非 200/解析失败/token 缺失/断网 → 纯规则结果。
            let verdict = fallbackClassify(ocrText)
            return LLMClassification(
                category: verdict.category,
                confidence: verdict.confidence,
                extractedFieldsJSON: verdict.extractedFieldsJSON,
                suggestedAction: verdict.suggestedAction,
                temporaryLikelihood: verdict.temporaryLikelihood
            )
        }
    }

    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
        guard isLiveMode() else {
            return try await mock.explainBestShot(candidates: candidates)
        }
        do {
            return try await remote.explainBestShot(candidates: candidates)
        } catch {
            return BestShotExplanation(
                keepIndex: 0,
                reason: "解释服务暂不可用，已按本地评分推荐第 1 张"
            )
        }
    }
}
