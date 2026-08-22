// MARK: - QualityDSPTests
// 职责：T06 低质量检测单测——拉普拉斯方差清晰度单调性、曝光直方图触底、
//       归一化边界（极小图）、EXIF 夜间白名单判定。
// 任务卡：T06。全部纯函数，CI 模拟器可验证。

import XCTest
@testable import AIPhotoInbox

final class QualityDSPTests: XCTestCase {

    /// 确定性伪随机数（LCG）。
    private func lcgSequence(seed: UInt64, count: Int) -> [UInt64] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    private func noiseGray(side: Int, seed: UInt64) -> [UInt8] {
        lcgSequence(seed: seed, count: side * side).map { UInt8($0 % 256) }
    }

    /// 3×3 均值盒式模糊（模拟失焦）。
    private func boxBlur(_ gray: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: gray.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                var count = 0
                for dy in -1...1 where y + dy >= 0 && y + dy < height {
                    for dx in -1...1 where x + dx >= 0 && x + dx < width {
                        sum += Int(gray[(y + dy) * width + x + dx])
                        count += 1
                    }
                }
                output[y * width + x] = UInt8(sum / count)
            }
        }
        return output
    }

    // MARK: 清晰度（验收：锐利 vs 模糊单调性）

    func testClaritySharpImageScoresAboveBlurredVersion() {
        let side = 32
        let sharp = noiseGray(side: side, seed: 7)
        let blurred = boxBlur(sharp, width: side, height: side)

        let sharpScore = ImageQualityDSP.clarityScore(grayPixels: sharp, width: side, height: side)!
        let blurredScore = ImageQualityDSP.clarityScore(grayPixels: blurred, width: side, height: side)!

        XCTAssertGreaterThan(sharpScore, blurredScore, "同一图案模糊后清晰度必须下降")
        XCTAssertGreaterThanOrEqual(blurredScore, 0)
        XCTAssertLessThanOrEqual(sharpScore, 1)
    }

    func testClarityFlatImageIsZero() {
        let flat = Array(repeating: UInt8(128), count: 100)
        XCTAssertEqual(ImageQualityDSP.clarityScore(grayPixels: flat, width: 10, height: 10), 0)
    }

    // MARK: 归一化边界（验收：极小图不崩且有定义行为）

    func testClarityTinyImagesHaveDefinedBehavior() {
        XCTAssertNil(ImageQualityDSP.clarityScore(grayPixels: [], width: 0, height: 0))
        XCTAssertNil(ImageQualityDSP.clarityScore(grayPixels: [1, 2, 3], width: 3, height: 3))
        XCTAssertEqual(ImageQualityDSP.clarityScore(grayPixels: [128], width: 1, height: 1), 0)
        XCTAssertEqual(
            ImageQualityDSP.clarityScore(grayPixels: [1, 2, 3, 4], width: 2, height: 2),
            0,
            "2×2 无内部像素，定义为 0 分"
        )
    }

    // MARK: 曝光（验收：全黑/全白触底）

    func testExposureFullySaturatedAndBlackTouchBottom() {
        let side = 16
        let allWhite = Array(repeating: UInt8(255), count: side * side)
        let allBlack = Array(repeating: UInt8(0), count: side * side)
        XCTAssertEqual(ImageQualityDSP.exposureScore(grayPixels: allWhite, width: side, height: side), 0)
        XCTAssertEqual(ImageQualityDSP.exposureScore(grayPixels: allBlack, width: side, height: side), 0)
    }

    func testExposureMidtoneIsFullScore() {
        let midtone = Array(repeating: UInt8(128), count: 64)
        XCTAssertEqual(ImageQualityDSP.exposureScore(grayPixels: midtone, width: 8, height: 8), 1)
    }

    func testExposurePartialBadPixelsScaleLinearly() {
        // 100 像素中 10 过曝 + 20 欠曝 → 得分 0.70。
        var pixels = Array(repeating: UInt8(128), count: 100)
        for index in 0..<10 { pixels[index] = 255 }
        for index in 10..<30 { pixels[index] = 0 }
        XCTAssertEqual(
            ImageQualityDSP.exposureScore(grayPixels: pixels, width: 10, height: 10)!,
            0.70,
            accuracy: 0.0001
        )
    }

    func testExposureInvalidInputReturnsNil() {
        XCTAssertNil(ImageQualityDSP.exposureScore(grayPixels: [], width: 0, height: 0))
        XCTAssertNil(ImageQualityDSP.exposureScore(grayPixels: [1], width: 2, height: 2))
    }

    // MARK: RGBA → 灰度

    func testLumaConversion() {
        // 纯红(255,0,0)→76；纯白→255；长度不符 → nil。
        XCTAssertEqual(
            ImageQualityDSP.lumaFromRGBA(rgbaBytes: [255, 0, 0, 255, 255, 255, 255, 255]),
            [76, 255]
        )
        XCTAssertNil(ImageQualityDSP.lumaFromRGBA(rgbaBytes: [1, 2, 3]))
    }

    // MARK: EXIF 夜间白名单（验收：不同字典豁免/不豁免）

    func testNightWhitelistSceneTypeThreeExempts() {
        XCTAssertTrue(NightWhitelist.isNightLongExposure(["SceneCaptureType": 3]))
        XCTAssertTrue(NightWhitelist.isNightLongExposure(["SceneCaptureType": NSNumber(value: 3)]))
        XCTAssertFalse(NightWhitelist.isNightLongExposure(["SceneCaptureType": 0]))
    }

    func testNightWhitelistLongExposureExempts() {
        XCTAssertTrue(NightWhitelist.isNightLongExposure(["ExposureTime": 0.8]))
        XCTAssertFalse(NightWhitelist.isNightLongExposure(["ExposureTime": 0.02]), "普通快照不豁免")
    }

    func testNightWhitelistHighISOWithSlowShutterExempts() {
        XCTAssertTrue(NightWhitelist.isNightLongExposure([
            "ISOSpeedRatings": [NSNumber(value: 6400)],
            "ExposureTime": 0.125,
        ]))
        // 高 ISO 但快门很快（防抖手持夜景模式之外的普通场景）→ 不豁免。
        XCTAssertFalse(NightWhitelist.isNightLongExposure([
            "ISOSpeedRatings": [NSNumber(value: 6400)],
            "ExposureTime": 0.03,
        ]))
    }

    func testNightWhitelistMissingFieldsDefaultsToNoExemption() {
        XCTAssertFalse(NightWhitelist.isNightLongExposure([:]))
        XCTAssertFalse(NightWhitelist.isNightLongExposure(["ExposureTime": "not-a-number"]))
    }
}
