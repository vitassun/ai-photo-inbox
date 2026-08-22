// MARK: - VisionIntegrationTests
// 职责：T08 单测——多请求结果聚合纯函数、失败回退中性值、受控并发调度；
//       模拟器冒烟：analyze 全链成功且美学维度按预期回退中性值
//       （模拟器跑不了美学请求是 Apple 确认的预期行为，真机才有真实分数）。
// 任务卡：T08。CI 模拟器可验证。

import XCTest
import CoreGraphics
import UIKit
@testable import AIPhotoInbox

final class VisionResultAggregatorTests: XCTestCase {

    func testAggregationNormalizesEachDimension() {
        let result = VisionResultAggregator.aggregate(
            clarity: 0.73,
            aesthetics: 0.42,
            faceQuality: 0.9,
            saliency: 0.11
        )
        XCTAssertEqual(result.clarity, 0.73, accuracy: 0.0001)
        XCTAssertEqual(result.aesthetics, 0.42, accuracy: 0.0001)
        XCTAssertEqual(result.faceQuality, 0.9, accuracy: 0.0001)
        XCTAssertEqual(result.saliency, 0.11, accuracy: 0.0001)
    }

    func testMissingDimensionFallsBackToNeutralNotZero() {
        // 铁律：失败/缺失回退 0.5，绝不按 0 分拉低所有照片。
        let result = VisionResultAggregator.aggregate(
            clarity: nil,
            aesthetics: nil,
            faceQuality: nil,
            saliency: nil
        )
        XCTAssertEqual(result.clarity, 0.5)
        XCTAssertEqual(result.aesthetics, 0.5)
        XCTAssertEqual(result.faceQuality, 0.5)
        XCTAssertEqual(result.saliency, 0.5)

        // 部分缺失：其余维度不受影响。
        let partial = VisionResultAggregator.aggregate(
            clarity: 0.8, aesthetics: nil, faceQuality: nil, saliency: 0.3
        )
        XCTAssertEqual(partial.clarity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(partial.aesthetics, 0.5)
        XCTAssertEqual(partial.faceQuality, 0.5)
        XCTAssertEqual(partial.saliency, 0.3, accuracy: 0.0001)
    }

    func testOutOfRangeValuesAreClamped() {
        let result = VisionResultAggregator.aggregate(
            clarity: 1.7,
            aesthetics: -0.4,
            faceQuality: 2.0,
            saliency: -5
        )
        XCTAssertEqual(result.clarity, 1.0)
        XCTAssertEqual(result.aesthetics, 0)
        XCTAssertEqual(result.faceQuality, 1.0)
        XCTAssertEqual(result.saliency, 0)
    }
}

final class BoundedConcurrencyRunnerTests: XCTestCase {

    /// 线程安全计数器。
    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        func decrement() -> Int { lock.lock(); defer { lock.unlock() }; value -= 1; return value }
    }

    func testConcurrencyCapAndExactCompletionCount() {
        let itemCount = 20
        let cap = 3

        let active = Counter()
        var peak = 0
        var completions = 0
        let counterLock = NSLock()
        let peakLock = NSLock()

        let finished = expectation(description: "all items done")
        BoundedConcurrencyRunner.run(
            itemCount: itemCount,
            maxConcurrent: cap
        ) { _, done in
            let nowActive = active.increment()
            peakLock.lock()
            peak = max(peak, nowActive)
            peakLock.unlock()

            // 模拟真实工作耗时，让并发窗口有重叠机会。
            Thread.sleep(forTimeInterval: 0.01)
            _ = active.decrement()

            counterLock.lock()
            completions += 1
            counterLock.unlock()
            done()
        } onFinish: {
            XCTAssertEqual(Thread.isMainThread, false)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertLessThanOrEqual(peak, cap, "并发峰值不得超过上限")
        XCTAssertEqual(completions, itemCount, "完成计数必须精确不丢")
    }

    func testZeroItemsFinishesImmediatelyOnce() {
        var finishCount = 0
        let lock = NSLock()
        let finished = expectation(description: "finish")
        BoundedConcurrencyRunner.run(
            itemCount: 0,
            maxConcurrent: 4,
            worker: { _, _ in XCTFail("空任务集不应执行任何 worker") },
            onFinish: {
                lock.lock(); finishCount += 1; lock.unlock()
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(finishCount, 1, "onFinish 必须恰好回调一次")
    }
}

final class VisionAnalysisSmokeTests: XCTestCase {

    func testAnalyzeSyntheticImageSucceedsWithNeutralAestheticsOnSimulator() throws {
        #if targetEnvironment(simulator)
        // 合成噪声图（确定性 LCG）。
        let side = 64
        var state: UInt64 = 12345
        var rgba = [UInt8]()
        rgba.reserveCapacity(side * side * 4)
        for _ in 0..<(side * side) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8((state >> 33) % 256)
            rgba.append(contentsOf: [value, value, value, 255])
        }
        let context = try XCTUnwrap(CGContext(
            data: &rgba,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let jpeg = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.9))

        var captured: Result<VisionAnalysisResult, Error>?
        let done = expectation(description: "analyze done")
        VisionAnalysisService().analyze(imageData: jpeg) { result in
            captured = result
            done.fulfill()
        }
        wait(for: [done], timeout: 60)

        let result = try XCTUnwrap(captured?.get())
        // 四维全部落在 [0,1]；模拟器上美学请求必然失败 → 中性值 0.5。
        for (name, score) in [("clarity", result.clarity), ("aesthetics", result.aesthetics),
                              ("faceQuality", result.faceQuality), ("saliency", result.saliency)] {
            XCTAssertTrue((0.0...1.0).contains(score), "\(name) 越界：\(score)")
        }
        XCTAssertEqual(result.aesthetics, 0.5, "模拟器无美学能力，应回退中性值而非报错/0 分")
        #else
        throw XCTSkip("美学分数断言仅适用于模拟器（真机有真实美学分数）")
        #endif
    }
}
