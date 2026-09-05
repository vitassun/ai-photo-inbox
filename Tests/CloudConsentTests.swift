// MARK: - CloudConsentTests
// 职责：T18 云端同意门闩——默认关、持久化、PRD 文案逐字防篡改、
//       权限展示映射全覆盖、门闩关闭时零出网/开启时放行的端到端断言。
// 任务卡：T18。CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class CloudConsentTests: XCTestCase {

    private final class RecordingLLM: LLMClientProtocol {
        var calls = 0
        var shouldFail = false

        func explainBestShot(candidates: [CandidateDescription]) async throws -> BestShotExplanation {
            calls += 1
            if shouldFail { throw NSError(domain: "test", code: 1) }
            return BestShotExplanation(keepIndex: 1, reason: "remote")
        }
    }

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

    func testConsentGatesRemoteAndFallsBackOnFailure() async throws {
        let database = try PhotoLibraryDatabase.inMemory()
        let store = GRDBKeyValueStore(database: database)
        let remote = RecordingLLM()
        let client = ConsentGatedLLMClient(store: store, remote: remote)
        let candidates = [CandidateDescription(desc: "a"), CandidateDescription(desc: "b")]

        let offline = try await client.explainBestShot(candidates: candidates)
        XCTAssertEqual(offline.keepIndex, 0)
        XCTAssertEqual(remote.calls, 0, "未同意时不得调用远端")

        CloudConsent.setEnabled(true, store: store)
        let online = try await client.explainBestShot(candidates: candidates)
        XCTAssertEqual(online.keepIndex, 1)
        XCTAssertEqual(remote.calls, 1)

        remote.shouldFail = true
        let fallback = try await client.explainBestShot(candidates: candidates)
        XCTAssertEqual(fallback.keepIndex, 0, "远端失败必须回退本地结果")
        XCTAssertEqual(remote.calls, 2)
    }

}
