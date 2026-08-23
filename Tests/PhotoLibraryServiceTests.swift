// MARK: - PhotoLibraryServiceTests
// 职责：T02 授权/映射纯函数的单测。全部不接触 PhotoKit 类型
//       （映射入参为 raw Int / 快照结构体），CI 模拟器可跑。
// 任务卡：T02。

import XCTest
@testable import AIPhotoInbox

final class PhotoLibraryServiceTests: XCTestCase {

    // MARK: 授权状态映射（验收：5 种枚举一一对应，不漏 restricted/limited）

    func testAuthorizationStatusRawMappingCoversAllFiveCases() {
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(0), .notDetermined)
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(1), .restricted)
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(2), .denied)
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(3), .authorized)
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(4), .limited)
    }

    func testAuthorizationStatusUnknownRawFallsBackToNotDetermined() {
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(99), .notDetermined)
        XCTAssertEqual(SystemPhotoLibraryService.mapAuthorizationStatusRaw(-1), .notDetermined)
    }

    // MARK: AssetRecord 映射（验收：favorite/isEdited/isScreenshot/duration 正确填充）

    private func makeSnapshot(
        id: String = "asset-1",
        favorite: Bool = false,
        isEdited: Bool = false,
        mediaTypeRaw: Int = 1,
        pixelWidth: Int = 100,
        pixelHeight: Int = 80,
        duration: Double = 0,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        isScreenshot: Bool = false,
        isLivePhoto: Bool = false,
        locallyAvailable: Bool = true,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> PHAssetSnapshot {
        PHAssetSnapshot(
            localIdentifier: id,
            favorite: favorite,
            isEdited: isEdited,
            mediaTypeRaw: mediaTypeRaw,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            creationDate: creationDate,
            modificationDate: modificationDate,
            isScreenshot: isScreenshot,
            isLivePhoto: isLivePhoto,
            locallyAvailable: locallyAvailable,
            latitude: latitude,
            longitude: longitude
        )
    }

    func testAssetRecordMappingFillsAllFields() {
        let creation = Date(timeIntervalSince1970: 1_700_000_000)
        // 三个布尔的取值刻意错开（favorite≠isEdited、isEdited≠isScreenshot），
        // 若 makeAssetRecord 里实参标签互换，此用例必红。
        let record = makeSnapshot(
            favorite: true,
            isEdited: false,
            mediaTypeRaw: 1,
            pixelWidth: 1920,
            pixelHeight: 1080,
            creationDate: creation,
            isScreenshot: true
        ).makeAssetRecord()

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.localIdentifier, "asset-1")
        XCTAssertEqual(record?.favorite, true)
        XCTAssertEqual(record?.isEdited, false)
        XCTAssertEqual(record?.mediaType, .image)
        XCTAssertEqual(record?.pixelCount, 1920 * 1080)
        XCTAssertEqual(record?.duration, 0)          // 照片时长恒 0
        XCTAssertEqual(record?.creationDate, creation)
        XCTAssertEqual(record?.isScreenshot, true)

        // 反向组合补齐 favorite↔isScreenshot 的区分度（上组两者同真）。
        let second = makeSnapshot(favorite: false, isEdited: true, isScreenshot: false).makeAssetRecord()
        XCTAssertEqual(second?.favorite, false)
        XCTAssertEqual(second?.isEdited, true)
        XCTAssertEqual(second?.isScreenshot, false)
    }

    func testVideoTypeAndDurationMapping() {
        let record = makeSnapshot(mediaTypeRaw: 2, duration: 12.5).makeAssetRecord()
        XCTAssertEqual(record?.mediaType, .video)
        XCTAssertEqual(record?.duration, 12.5)
    }

    func testUnknownMediaTypeRawMapsToUnknown() {
        let record = makeSnapshot(mediaTypeRaw: 99).makeAssetRecord()
        XCTAssertEqual(record?.mediaType, .unknown)
    }

    // MARK: creationDate 回退策略（验收：nil 回退 modificationDate；全仓唯一实现点）

    func testCreationDateNilFallsBackToModificationDate() {
        let modification = Date(timeIntervalSince1970: 1_700_001_000)
        let record = makeSnapshot(creationDate: nil, modificationDate: modification).makeAssetRecord()
        XCTAssertEqual(record?.creationDate, modification)
    }

    func testCreationDatePresentIsNotOverridden() {
        let creation = Date(timeIntervalSince1970: 1_700_000_000)
        let modification = Date(timeIntervalSince1970: 1_700_009_999)
        let record = makeSnapshot(creationDate: creation, modificationDate: modification).makeAssetRecord()
        XCTAssertEqual(record?.creationDate, creation)
    }

    func testBothDatesNilKeepsNilCreationDate() {
        let record = makeSnapshot(creationDate: nil, modificationDate: nil).makeAssetRecord()
        XCTAssertNotNil(record)
        XCTAssertNil(record?.creationDate)
    }

    // MARK: 全量映射

    func testSnapshotWithoutIdentifierIsDropped() {
        let records = SystemPhotoLibraryService.assetRecords(from: [
            makeSnapshot(id: ""),
            makeSnapshot(id: "asset-ok"),
        ])
        XCTAssertEqual(records.map(\.localIdentifier), ["asset-ok"])
    }

    // MARK: fetchAssets(matching:) 契约（验收：未知 localIdentifier 忽略不崩）

    func testFetchMatchingIgnoresUnknownIdentifiers() {
        let records = SystemPhotoLibraryService.assetRecords(
            from: [
                makeSnapshot(id: "A"),
                makeSnapshot(id: "B"),
                makeSnapshot(id: "C"),
            ],
            matching: ["B", "ghost-id", "C"]
        )
        // 未知 id 静默忽略、不崩、不出现在结果里。
        XCTAssertEqual(records.map(\.localIdentifier), ["B", "C"])
    }

    func testFetchMatchingPreservesRequestOrderAndDeduplicates() {
        let records = SystemPhotoLibraryService.assetRecords(
            from: [
                makeSnapshot(id: "A"),
                makeSnapshot(id: "C"),
            ],
            matching: ["C", "A", "C"]
        )
        XCTAssertEqual(records.map(\.localIdentifier), ["C", "A"])
    }

    func testFetchMatchingEmptyRequestReturnsEmpty() {
        let records = SystemPhotoLibraryService.assetRecords(
            from: [makeSnapshot(id: "A")],
            matching: []
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testFetchMatchingAllUnknownReturnsEmpty() {
        let records = SystemPhotoLibraryService.assetRecords(
            from: [makeSnapshot(id: "A")],
            matching: ["x", "y"]
        )
        XCTAssertTrue(records.isEmpty)
    }
}
