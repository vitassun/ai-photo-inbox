// MARK: - LLMClientTests
// 职责：T13 单测——URLProtocol mock 全分支（正常解析/超时降级/500 降级/
//       畸形 JSON 降级/token 缺失自动 MOCK）、重试至多一次、降级等价断言。
// 任务卡：T13。CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

/// URLProtocol 桩：按注册的 handler 应答，并计数请求。
final class MockURLProtocol: URLProtocol {

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private(set) static var requestCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); handler = nil; requestCount = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LLMClientTests: XCTestCase {

    private var session: URLSession!
    private let base = URL(string: "https://llm.mock.local")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.timeoutIntervalForRequest = AppConfig.llmTimeoutSeconds
        session = URLSession(configuration: configuration)
    }

    private func makeRemote(token: String? = "test-token") -> RemoteLLMClient {
        RemoteLLMClient(baseURL: base, tokenProvider: { token }, session: session)
    }

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: 正常响应解析

    func testClassificationParsesContractFields() async throws {
        MockURLProtocol.handler = { _ in
            let body = """
            {"category":"courier","confidence":0.72,
             "extracted_fields":{"tracking_number":"SF1234567890"},
             "suggested_action":"提取单号，可复制去物流查询",
             "temporary_likelihood":0.55}
            """
            return (self.httpResponse(200), Data(body.utf8))
        }

        let result = try await makeRemote().classifyScreenshot(ocrText: "顺丰快递 单号 SF1234567890")
        XCTAssertEqual(result.category, "courier")
        XCTAssertEqual(result.confidence, 0.72, accuracy: 0.0001)
        XCTAssertTrue(result.extractedFieldsJSON.contains("SF1234567890"))
        XCTAssertGreaterThan(result.suggestedAction.count, 0)
        XCTAssertEqual(result.temporaryLikelihood, 0.55, accuracy: 0.0001)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "一次成功不应重试")
    }

    func testExplanationParsesContractFields() async throws {
        MockURLProtocol.handler = { _ in
            (self.httpResponse(200), Data(#"{"keep_index":0,"reason":"第 0 张清晰度最高"}"#.utf8))
        }
        let explanation = try await makeRemote().explainBestShot(
            candidates: [CandidateDescription(desc: "第0张 清晰 曝光正常")]
        )
        XCTAssertEqual(explanation.keepIndex, 0)
        XCTAssertEqual(explanation.reason, "第 0 张清晰度最高")
    }

    // MARK: 降级分支

    func testTimeoutFallsBackToRuleResult() async throws {
        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let resilient = ResilientLLMClient(
            remote: makeRemote(),
            fallbackClassify: { ScreenshotRuleClassifier.classify(ocrText: $0, isScreenshot: true, aspectRatio: 2.16) },
            isLiveMode: { true }
        )

        let text = "顺丰快递 运单号 SF1234567890123 已揽收"
        let degraded = try await resilient.classifyScreenshot(ocrText: text)
        let pureRule = ScreenshotRuleClassifier.classify(ocrText: text, isScreenshot: true, aspectRatio: 2.16)

        // 等价断言：降级结果与纯规则路径完全一致。
        XCTAssertEqual(degraded.category, pureRule.category)
        XCTAssertEqual(degraded.confidence, pureRule.confidence, accuracy: 0.0001)
        XCTAssertEqual(degraded.extractedFieldsJSON, pureRule.extractedFieldsJSON)
        XCTAssertEqual(degraded.suggestedAction, pureRule.suggestedAction)
        XCTAssertEqual(degraded.temporaryLikelihood, pureRule.temporaryLikelihood)

        // 重试策略：超时后至多重试 1 次 → 共 2 次请求。
        XCTAssertEqual(MockURLProtocol.requestCount, AppConfig.llmMaxRetries + 1)
    }

    func testServerErrorFallsBackWithSingleRetry() async throws {
        MockURLProtocol.handler = { _ in (self.httpResponse(500), Data()) }
        _ = try? await ResilientLLMClient(
            remote: makeRemote(),
            fallbackClassify: { ScreenshotRuleClassifier.classify(ocrText: $0, isScreenshot: true, aspectRatio: 2.16) },
            isLiveMode: { true }
        ).classifyScreenshot(ocrText: "验证码 552211")
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "首次 + 至多一次重试")
    }

    func testMalformedJSONFallsBack() async throws {
        MockURLProtocol.handler = { _ in (self.httpResponse(200), Data("这不是 JSON".utf8)) }
        let result = try await ResilientLLMClient(
            remote: makeRemote(),
            fallbackClassify: { ScreenshotRuleClassifier.classify(ocrText: $0, isScreenshot: true, aspectRatio: 2.16) },
            isLiveMode: { true }
        ).classifyScreenshot(ocrText: "一段没有任何信号的普通文本")

        XCTAssertEqual(result.category, "other")
        XCTAssertTrue(result.suggestedAction == "manual_review", "无信号文本规则结果应为待人工确认")
    }

    func testExplainFailureFallsBackToNeutralCopy() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let explanation = try await ResilientLLMClient(
            remote: makeRemote(),
            fallbackClassify: { ScreenshotRuleClassifier.classify(ocrText: $0, isScreenshot: true, aspectRatio: 2.16) },
            isLiveMode: { true }
        ).explainBestShot(candidates: [CandidateDescription(desc: "第0张"), CandidateDescription(desc: "第1张")])
        XCTAssertEqual(explanation.keepIndex, 0)
        XCTAssertFalse(explanation.reason.isEmpty)
    }

    // MARK: token 缺失 → 自动 MOCK

    func testMissingTokenSkipsNetworkAndUsesMock() async throws {
        let remote = makeRemote(token: nil)
        do {
            _ = try await remote.classifyScreenshot(ocrText: "任意")
            XCTFail("无 token 的远端调用应抛 tokenMissing")
        } catch {}

        // 弹性客户端在 MOCK 模式（isLiveMode=false）下走离线实现，零网络请求。
        MockURLProtocol.reset()
        let resilient = ResilientLLMClient(
            remote: remote,
            fallbackClassify: { ScreenshotRuleClassifier.classify(ocrText: $0, isScreenshot: true, aspectRatio: 2.16) },
            isLiveMode: { false }
        )
        let mockResult = try await resilient.classifyScreenshot(ocrText: "验证码 778899")
        XCTAssertEqual(mockResult.category, "verification_code", "MOCK 模式给确定性结果")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "MOCK 模式零网络请求")
    }
}
