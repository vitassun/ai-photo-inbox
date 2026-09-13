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

    // MARK: 事务与错误处理（T07 补充验收）

    /// 注入写入失败：阶段切换不得成功，内存状态必须回滚到写入前。
    /// 恢复后只能读到"完整的旧状态"或"完整的新状态"，不能是半套。
    func testAdvanceFailsAndRollsBackWhenPhaseWriteFails() {
        let store = InMemoryKeyValueStore()
        let machine = ScanStateMachine(store: store)
        XCTAssertTrue(machine.advance())          // idle → fetching
        XCTAssertEqual(machine.phase, .fetching)

        // 让阶段写入全部失败（模拟磁盘满 / 事务中断）。
        store.failingKeys = ["scan.phase"]

        XCTAssertFalse(machine.advance(), "写盘失败时不得声明阶段切换成功")
        XCTAssertEqual(machine.phase, .fetching, "失败必须回滚到写入前的阶段")
        XCTAssertNotNil(machine.lastPersistenceError)

        // 恢复后只能读到完整的旧状态（fetching），不能读到 hashing。
        let revived = ScanStateMachine(store: store)
        XCTAssertEqual(revived.phase, .fetching)
    }

    /// 暂停失败时不得让内存进入 paused：否则 UI 显示已暂停、
    /// 但"暂停前阶段"从未落盘，恢复会退化成从头重扫。
    func testPauseFailsAndKeepsActivePhaseWhenWriteFails() {
        let store = InMemoryKeyValueStore()
        let machine = ScanStateMachine(store: store)
        XCTAssertTrue(machine.advance())          // fetching
        store.failingKeys = ["scan.phase"]

        XCTAssertFalse(machine.pause(reason: "用户暂停"))
        XCTAssertEqual(machine.phase, .fetching, "失败时内存不得进入 paused")
        XCTAssertTrue(machine.isActive)
    }

    /// 版本不符触发基线写入失败：内存仍安全回到 idle，并暴露错误。
    func testFeatureVersionMismatchReportsWhenBaselineWriteFails() {
        let store = InMemoryKeyValueStore(prepopulated: [
            "scan.featureVersion": "999",
            "scan.phase": "",
            "scan.progress": "0.5",
        ])
        store.failingKeys = ["scan.phase"]

        let machine = ScanStateMachine(store: store)
        XCTAssertEqual(machine.phase, .idle, "无法写入基线也必须安全回到 idle")
        XCTAssertNotNil(machine.lastPersistenceError, "初始化写入失败要如实暴露")
    }

    /// 进度写入失败不得推进内部基线：否则后续真实写入会被节流掉，
    /// 造成"以为存了、其实没存"。
    func testProgressBaselineNotAdvancedWhenWriteFails() {
        let store = InMemoryKeyValueStore()
        let machine = ScanStateMachine(store: store)
        XCTAssertTrue(machine.advance())          // fetching

        store.failingKeys = ["scan.progress"]
        // force=true 路径（进度到 1）会尝试写入并失败。
        machine.setProgress(1)
        XCTAssertNotNil(machine.lastPersistenceError)

        // 解除失败后同一进度必须再尝试写入并成功。
        store.failingKeys = []
        store.resetWriteAttempts()
        machine.setProgress(0)
        XCTAssertTrue(
            store.writeAttempts.contains("scan.progress"),
            "失败后基线未前进，同一进度应重新写入"
        )
        let revived = ScanStateMachine(store: store)
        XCTAssertEqual(revived.phase, .fetching)
        XCTAssertEqual(revived.progress, 0, accuracy: 1e-9)
    }

    /// 阶段、进度、暂停前阶段必须落在同一次原子提交里：
    /// 不能出现"阶段已切、进度还是旧值"的中间态。
    func testPauseCommitsPhaseAndProgressTogether() {
        let store = InMemoryKeyValueStore()
        let machine = ScanStateMachine(store: store)
        XCTAssertTrue(machine.advance())          // fetching
        XCTAssertTrue(machine.advance())          // hashing
        machine.setProgress(0.6)
        XCTAssertTrue(machine.pause(reason: "手动暂停"))

        // 任一键写入失败，整批都不应生效。
        let revived = ScanStateMachine(store: store)
        XCTAssertEqual(revived.phase, .paused(failReason: "手动暂停"))
        XCTAssertEqual(revived.progress, 0.6, accuracy: 1e-9)
        XCTAssertTrue(revived.resume())
        XCTAssertEqual(revived.phase, .hashing, "暂停前阶段必须与暂停同批落盘")
        XCTAssertEqual(revived.progress, 0.6, accuracy: 1e-9)
    }
}
