// MARK: - KeepScoreTests
// 职责：保留分评分引擎测试（值域/确定性/收藏加权/冷启动翻倍/冗余惩罚）。
// 任务卡：T06 / T01。纯逻辑，模拟器可跑。

import XCTest
@testable import AIPhotoInbox

final class KeepScoreTests: XCTestCase {

    private func inputs(
        clarity: Double = 0.5,
        faceQuality: Double = 0.5,
        aesthetics: Double = 0.5,
        saliency: Double = 0.5,
        redundancy: Double = 0,
        isFavorite: Bool = false
    ) -> KeepScore.Inputs {
        KeepScore.Inputs(
            clarity: clarity,
            faceQuality: faceQuality,
            aesthetics: aesthetics,
            saliency: saliency,
            redundancy: redundancy,
            isFavorite: isFavorite
        )
    }

    func testScoreStaysWithinUnitRange() {
        let worst = KeepScore.score(inputs: inputs(
            clarity: 0, faceQuality: 0, aesthetics: 0, saliency: 0, redundancy: 1
        ))
        let best = KeepScore.score(inputs: inputs(
            clarity: 1, faceQuality: 1, aesthetics: 1, saliency: 1, isFavorite: true
        ))
        XCTAssertEqual(worst, 0, accuracy: 1e-9) // 冗余惩罚打穿下界 → 钳到 0
        XCTAssertGreaterThanOrEqual(best, 0)
        XCTAssertLessThanOrEqual(best, 1)
    }

    func testNeutralInputsGiveDeterministicScore() {
        let value = KeepScore.score(inputs: inputs())
        let w = KeepWeights()
        let expected = 0.5 * (w.clarity + w.faceQuality + w.aesthetics + w.saliency)
        XCTAssertEqual(value, expected, accuracy: 1e-9)
    }

    func testFavoriteRaisesScore() {
        let plain = KeepScore.score(inputs: inputs())
        let faved = KeepScore.score(inputs: inputs(isFavorite: true))
        XCTAssertEqual(faved - plain, KeepWeights().favoriteBoost, accuracy: 1e-9)
    }

    func testColdStartDoublesFavoriteWeight() {
        // 冷启动（hasUserData=false）：收藏加权翻倍 → 分差恰为一个基础 favoriteBoost。
        let warm = KeepScore.score(inputs: inputs(isFavorite: true), hasUserData: true)
        let cold = KeepScore.score(inputs: inputs(isFavorite: true), hasUserData: false)
        XCTAssertEqual(cold - warm, KeepWeights().favoriteBoost, accuracy: 1e-9)
    }

    func testColdStartDoesNotAffectUnfavoritedAssets() {
        XCTAssertEqual(
            KeepScore.score(inputs: inputs(), hasUserData: false),
            KeepScore.score(inputs: inputs(), hasUserData: true),
            accuracy: 1e-9
        )
    }

    func testRedundancyPenaltyReducesScore() {
        let unique = KeepScore.score(inputs: inputs())
        let duplicate = KeepScore.score(inputs: inputs(redundancy: 1))
        XCTAssertEqual(unique - duplicate, KeepWeights().redundancyPenalty, accuracy: 1e-9)
    }

    func testCustomWeightsAreRespected() {
        var weights = KeepWeights()
        weights.clarity = 1
        weights.faceQuality = 0
        weights.aesthetics = 0
        weights.saliency = 0
        weights.redundancyPenalty = 0
        weights.favoriteBoost = 0
        let value = KeepScore.score(inputs: inputs(clarity: 0.7), weights: weights)
        XCTAssertEqual(value, 0.7, accuracy: 1e-9)
    }
}
