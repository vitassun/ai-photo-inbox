// MARK: - ScanStateMachineTests
// 职责：扫描状态机测试——流水线推进、暂停恢复、断点续扫（跨实例持久化）、版本迁移。
// 任务卡：T07 / T01。KeyValueStore 注入内存实现，模拟器可跑。

import XCTest
@testable import AIPhotoInbox

final class ScanStateMachineTests: XCTestCase {

    private func makeMachine() -> (ScanStateMachine, InMemoryKeyValueStore) {
        let store = InMemoryKeyValueStore()
        return (ScanStateMachine(store: store), store)
    }

    // MARK: 基本流转

    func testInitialPhaseIsIdleWithZeroProgress() {
        let (machine, _) = makeMachine()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.progress, 0)
        XCTAssertFalse(machine.isActive)
    }

    func testAdvanceWalksWholePipelineThenStops() {
        let (machine, _) = makeMachine()
        let expected: [ScanPhase] = [.fetching, .hashing, .embedding, .clustering, .scoring, .done]
        for step in expected {
            XCTAssertTrue(machine.advance(), "推进到 \(step) 应成功")
            XCTAssertEqual(machine.phase, step)
        }
        XCTAssertFalse(machine.advance()) // done 之后不再推进
        XCTAssertEqual(machine.phase, .done)
        XCTAssertFalse(machine.isActive)
    }

    func testProgressResetsOnAdvance() {
        let (machine, _) = makeMachine()
        machine.advance()
        machine.setProgress(0.8)
        machine.advance()
        XCTAssertEqual(machine.progress, 0)
    }

    // MARK: 暂停 / 恢复

    func testPauseSetsPausedWithReason() {
        let (machine, _) = makeMachine()
        machine.advance()
        XCTAssertTrue(machine.pause(reason: "电量不足"))
        XCTAssertEqual(machine.phase, .paused(failReason: "电量不足"))
        XCTAssertFalse(machine.isActive)
    }

    func testPauseFromIdleOrDoneIsRejected() {
        let (machine, _) = makeMachine()
        XCTAssertFalse(machine.pause(reason: "还没开始"))
        while machine.advance() {} // 推进到 done
        XCTAssertFalse(machine.pause(reason: "已经结束"))
        XCTAssertEqual(machine.phase, .done)
    }

    func testAdvanceFromPausedIsNoOp() {
        let (machine, _) = makeMachine()
        machine.advance()
        machine.pause(reason: "网络中断")
        XCTAssertFalse(machine.advance()) // 必须先 resume
        XCTAssertEqual(machine.phase, .paused(failReason: "网络中断"))
    }

    func testResumeRestoresPhaseAndContinues() {
        let (machine, _) = makeMachine()
        machine.advance() // fetching
        machine.advance() // hashing
        XCTAssertTrue(machine.pause(reason: "手动暂停"))
        XCTAssertTrue(machine.resume())
        XCTAssertEqual(machine.phase, .hashing)
        XCTAssertTrue(machine.isActive)
        XCTAssertTrue(machine.advance())
        XCTAssertEqual(machine.phase, .embedding)
    }

    func testResumeWithoutPauseIsNoOp() {
        let (machine, _) = makeMachine()
        XCTAssertFalse(machine.resume())
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: 断点续扫（跨实例持久化）

    func testStateSurvivesRecreationForCrashRecovery() {
        let (machine, store) = makeMachine()
        machine.advance() // fetching
        machine.setProgress(0.42)
        machine.pause(reason: "进程被杀")

        let revived = ScanStateMachine(store: store)
        XCTAssertEqual(revived.phase, .paused(failReason: "进程被杀"))
        XCTAssertEqual(revived.progress, 0.42, accuracy: 1e-9)
        XCTAssertTrue(revived.resume())
        XCTAssertEqual(revived.phase, .fetching)
        XCTAssertEqual(revived.progress, 0.42, accuracy: 1e-9) // 进度原样保留
    }

    func testFeatureVersionMismatchResetsProgress() {
        let (machine, store) = makeMachine()
        machine.advance()
        machine.setProgress(0.9)
        // 模拟旧版本残留：版本号对不上 → 新实例必须丢弃进度从头开始。
        store.setString("999", forKey: "scan.featureVersion")

        let revived = ScanStateMachine(store: store)
        XCTAssertEqual(revived.phase, .idle)
        XCTAssertEqual(revived.progress, 0)
        XCTAssertEqual(revived.phase, ScanStateMachine.pipeline.first)
    }

    // MARK: 进度钳制

    func testProgressIsClampedToUnitRange() {
        let (machine, _) = makeMachine()
        machine.advance()
        machine.setProgress(1.5)
        XCTAssertEqual(machine.progress, 1)
        machine.setProgress(-3)
        XCTAssertEqual(machine.progress, 0)
    }

    func testSetProgressIgnoredWhenNotActive() {
        let (machine, _) = makeMachine()
        machine.setProgress(0.5) // idle 阶段：忽略
        XCTAssertEqual(machine.progress, 0)
    }
}
