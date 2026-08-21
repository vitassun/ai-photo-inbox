// MARK: - SafetyRulesTests
// 职责：删除安全红线的全分支测试——这是全项目最重要的测试文件。
// 任务卡：T10 / T01。任何让本文件变红的 PR 一律拒绝合并。

import XCTest
@testable import AIPhotoInbox

final class SafetyRulesTests: XCTestCase {

    private func asset(
        id: String = "asset-1",
        favorite: Bool = false,
        edited: Bool = false
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            favorite: favorite,
            isEdited: edited,
            mediaType: .image,
            pixelWidth: 4032,
            pixelHeight: 3024,
            duration: 0,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isScreenshot: false
        )
    }

    // MARK: 红线分支

    func testFavoriteAssetCanNeverBePreselected() {
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(favorite: true), groupSize: 5, isOnlyInGroup: false
        ))
    }

    func testEditedAssetCanNeverBePreselected() {
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(edited: true), groupSize: 5, isOnlyInGroup: false
        ))
    }

    func testFavoriteAndEditedBeatsEverythingElse() {
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(favorite: true, edited: true), groupSize: 99, isOnlyInGroup: false
        ))
    }

    func testOnlyInGroupFlagCanNeverBePreselected() {
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(), groupSize: 1, isOnlyInGroup: true
        ))
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(), groupSize: 3, isOnlyInGroup: true
        ))
    }

    func testSingletonGroupCanNeverBePreselected() {
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(), groupSize: 1, isOnlyInGroup: false
        ))
        XCTAssertFalse(SafetyRules.canPreselectDelete(
            asset: asset(), groupSize: 0, isOnlyInGroup: false
        ))
    }

    func testPlainDuplicateCanBePreselected() {
        XCTAssertTrue(SafetyRules.canPreselectDelete(
            asset: asset(), groupSize: 4, isOnlyInGroup: false
        ))
    }

    // MARK: 红线常量钉死

    func testRedLineConstantsArePinned() {
        XCTAssertTrue(SafetyRules.neverDeleteFavorites)
        XCTAssertTrue(SafetyRules.neverDeleteEdited)
        XCTAssertTrue(SafetyRules.neverDeleteOnlyInGroup)
        XCTAssertFalse(SafetyRules.silentDeleteAllowed)
        // Debug 断言不崩 = 红线常量未被篡改。
        SafetyRules.validateRedLines()
    }

    // MARK: 组级过滤

    func testPreselectableMembersFiltersProtectedOnes() {
        let group = CandidateGroup(
            id: "g1",
            members: [
                asset(id: "plain"),
                asset(id: "faved", favorite: true),
                asset(id: "edited", edited: true),
                asset(id: "both", favorite: true, edited: true),
            ],
            reason: "时间连拍"
        )
        let allowed = SafetyRules.preselectableMembers(in: group)
        XCTAssertEqual(allowed.map { $0.localIdentifier }, ["plain"])
    }

    func testSingletonGroupHasNoPreselectableMembers() {
        let group = CandidateGroup(id: "g2", members: [asset(id: "lonely")], reason: "单张")
        XCTAssertTrue(SafetyRules.preselectableMembers(in: group).isEmpty)
    }
}
