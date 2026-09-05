// MARK: - RemoteLLMClient / MockLLMClient
// 职责：T13 LLM 兜底客户端。
//   RemoteLLMClient — URLSession 对接 backend explain 端点（Bearer 鉴权、8s 超时、至多重试一次）；
//   MockLLMClient   — 离线确定性结果（MOCK 默认模式，$0 成本）。
// 任务卡：T13。token 绝不入 git/日志；不在主线程同步等待（async 全程后台）。

import Foundation
import Security

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
        guard !candidates.isEmpty, candidates.count <= 32,
              candidates.allSatisfy({
                  let text = $0.desc.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !text.isEmpty && text.count <= 2_000
              }) else { throw LLMError.malformedResponse }
        let payload = candidates.map {
            ["desc": $0.desc.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let data = try await post(path: "/v1/groups/explain", body: ["candidates": payload])
        return try Self.decodeExplanation(data, candidateCount: candidates.count)
    }

    // MARK: 传输（含至多一次重试）

    private func post(path: String, body: [String: Any]) async throws -> Data {
        guard let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
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
                if error is CancellationError { throw error }
                // 只重试瞬时故障；鉴权、参数和服务端业务错误重试没有意义。
                if let llmError = error as? LLMError,
                   !Self.isRetryable(llmError) {
                    throw llmError
                }
                if attempt < AppConfig.llmMaxRetries {
                    // 短暂退避，避免在代理故障时立即重复打满连接池。
                    do {
                        try await Task.sleep(nanoseconds: 150_000_000)
                    } catch {
                        throw CancellationError()
                    }
                }
            }
        }
        throw lastError
    }

    private static func isRetryable(_ error: LLMError) -> Bool {
        switch error {
        case .httpStatus(let status):
            return [408, 425, 429, 500, 502, 503, 504].contains(status)
        case .tokenMissing, .malformedResponse, .retriesExhausted:
            return false
        }
    }

    // MARK: 解析（契约 §6.1/§6.2 snake_case 字段）


    static func decodeExplanation(
        _ data: Data,
        candidateCount: Int? = nil
    ) throws -> BestShotExplanation {
        struct Wire: Decodable {
            let keep_index: Int
            let reason: String
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let reason = wire.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wire.keep_index >= 0,
              candidateCount.map({ wire.keep_index < $0 }) ?? true,
              !reason.isEmpty,
              reason.count <= 2_000 else {
            throw LLMError.malformedResponse
        }
        return BestShotExplanation(keepIndex: wire.keep_index, reason: reason)
    }
}

// MARK: 离线 MOCK 实现（默认模式）

/// 确定性结果：验证码类给临时标记建议；其余按词表首命中给 copy 建议；
/// 无信号给 other + manual_review——与规则分类器的保守口径一致。
final class MockLLMClient: LLMClientProtocol {


    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
        guard !candidates.isEmpty else {
            throw RemoteLLMClient.LLMError.malformedResponse
        }
        BestShotExplanation(keepIndex: 0, reason: "MOCK：第 0 张综合特征最优（离线确定性结果）")
    }
}

// MARK: 弹性包装（降级铁律执行者）

/// 云端请求的唯一入口：开关关闭时立即走本地结果，远端失败时也自动降级。
/// 这样调用方不必自行复制同意判断；关闭开关后后续调用不会再创建远端请求。
final class ConsentGatedLLMClient: LLMClientProtocol {

    private let store: KeyValueStore
    private let remote: LLMClientProtocol
    private let fallback: LLMClientProtocol

    init(
        store: KeyValueStore,
        remote: LLMClientProtocol,
        fallback: LLMClientProtocol = MockLLMClient()
    ) {
        self.store = store
        self.remote = remote
        self.fallback = fallback
    }

    func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
        guard CloudConsent.isEnabled(store: store) else {
            return try await fallback.explainBestShot(candidates: candidates)
        }
        do {
            return try await remote.explainBestShot(candidates: candidates)
        } catch is CancellationError {
            // 取消由调用方发起时不要再执行一次本地兜底，保持任务可取消语义。
            throw CancellationError()
        } catch {
            return try await fallback.explainBestShot(candidates: candidates)
        }
    }
}

/// 远端 token 只从 Keychain 读取；缺失时 RemoteLLMClient 会直接返回 tokenMissing。
/// 测试和构建环境仍可通过 RemoteLLMClient 的 tokenProvider 注入假 token。
enum LLMTokenStore {
    private static let service = "com.aiphotoinbox.llm"
    private static let account = "bearer-token"

    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        if let data = result as? Data {
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false ? token : nil
        }
        let token = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}
