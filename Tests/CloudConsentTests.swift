// MARK: - CloudConsentTests
// 职责：T18 云端同意门闩——默认关、持久化、PRD 文案逐字防篡改、
//       权限展示映射全覆盖、门闩关闭时零出网/开启时放行的端到端断言。
// 任务卡：T18。CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class CloudConsentTests: XCTestCase {

    // MARK: 门闩状态机

    func testDefaultsToOffOnFreshStore() {
        let database = try! PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        XCTAssertFalse(CloudConsent.isEnabled(store: store), "默认必须关（红线 4）")
    }

    func testEnablePersistsAcrossStoreInstancesAndFlipsBack() {
        let database = try! PhotoLibraryDatabase.inMemory()

        let first = GRDBKeyValueStore(database: database)
        CloudConsent.setEnabled(true, store: first)
        XCTAssertTrue(CloudConsent.isEnabled(store: first))

        // 新实例读同一库 → 持久化生效（杀进程重开口径）。
        let second = GRDBKeyValueStore(database: database)
        XCTAssertTrue(CloudConsent.isEnabled(store: second))

        CloudConsent.setEnabled(false, store: second)
        XCTAssertFalse(CloudConsent.isEnabled(store: second), "关闭立即生效")
        XCTAssertFalse(CloudConsent.isEnabled(store: first), "同库另一实例同步读到关闭")
    }

    // MARK: PRD 文案逐字保护

    func testConsentNoticeMatchesPRDVerbatim() {
        XCTAssertEqual(
            CloudConsent.consentNotice,
            "候选缩略图与 OCR 文本将发送至我们的服务器并转发给 AI 服务商；服务商默认最长保留约 30 天"
        )
    }

    func testDestinationNoticeCoversExifStripping() {
        XCTAssertTrue(CloudConsent.destinationNotice.contains("EXIF/GPS"))
        XCTAssertTrue(CloudConsent.destinationNotice.contains("立即停止"))
    }

    // MARK: 权限展示映射（5 种授权状态全覆盖）

    func testPermissionCopyCoversAllFiveStatuses() {
        let statuses: [PhotoAuthorizationStatus] = [
            .notDetermined, .restricted, .denied, .authorized, .limited
        ]
        let titles = Set(statuses.map { PermissionCopy.presentation(for: $0).title })
        XCTAssertEqual(titles.count, 5, "五种状态的标题应互不相同")

        for status in statuses {
            let presentation = PermissionCopy.presentation(for: status)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.detail.isEmpty)
            let expectedSettings = status == .limited || status == .denied || status == .restricted
            XCTAssertEqual(presentation.needsSystemSettings, expectedSettings,
                           "\(status) 的系统设置入口判定不符")
        }
    }

    // MARK: 门闩端到端：关 → 零出网；开 → 放行

    func testResilientClientMakesZeroRequestsWhileConsentOff() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.handler = { [response = HTTPURLResponse(
            url: URL(string: "https://llm.mock.local")!, statusCode: 200,
            httpVersion: nil, headerFields: nil
        )!] _ in
            (response, Data(#"{"category":"courier","confidence":0.9,"extracted_fields":{},"suggested_action":"copy_text","temporary_likelihood":0.5}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let database = try! PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)

        let client = ResilientLLMClient(
            remote: RemoteLLMClient(
                baseURL: URL(string: "https://llm.mock.local")!,
                tokenProvider: { "test-token" },
                session: session
            ),
            fallbackClassify: { ocrText in
                ScreenshotRuleClassifier.classify(ocrText: ocrText, isScreenshot: true, aspectRatio: 1.8)
            },
            isLiveMode: { CloudConsent.isEnabled(store: store) }
        )

        // 关：走 MOCK 路径，零网络请求。
        let offResult = try await client.classifyScreenshot(ocrText: "随便一段文本")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "未同意时不得有任何出网请求")
        XCTAssertEqual(offResult.category, "other", "MOCK 无信号文本 → other + 待定")
        XCTAssertEqual(offResult.suggestedAction, "manual_review")

        // 开：恰好发出一次请求。
        CloudConsent.setEnabled(true, store: store)
        _ = try await client.classifyScreenshot(ocrText: "随便一段文本")
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "同意后放行远端请求")

        // 再关：立刻回落，不再增加请求。
        CloudConsent.setEnabled(false, store: store)
        _ = try await client.classifyScreenshot(ocrText: "随便一段文本")
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "关闭后新请求零出网")
    }
}
