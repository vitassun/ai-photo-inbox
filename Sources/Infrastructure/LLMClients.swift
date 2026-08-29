// MARK: - RemoteLLMClient / MockLLMClient
// 职责：T13 LLM 兜底客户端。
//   RemoteLLMClient — URLSession 对接 backend explain 端点（Bearer 鉴权、8s 超时、至多重试一次）；
//   MockLLMClient   — 离线确定性结果（MOCK 默认模式，$0 成本）。
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


    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
        BestShotExplanation(keepIndex: 0, reason: "MOCK：第 0 张综合特征最优（离线确定性结果）")
    }
}

// MARK: 弹性包装（降级铁律执行者）


