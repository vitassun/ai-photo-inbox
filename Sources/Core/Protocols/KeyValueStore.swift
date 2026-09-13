// MARK: - KeyValueStore
// 职责：键值持久化抽象。生产实现落 GRDB/UserDefaults（T03 适配），
//       单元测试注入 InMemoryKeyValueStore —— 状态机因此可在 CI 上验证断点续扫。
// 任务卡：T03 / T07。

import Foundation

/// 最小键值接口：只暴露字符串读写，序列化职责在调用方（保持协议面最小）。
/// 约定：setString 传 nil 等价于删除该键。
protocol KeyValueStore {
    func string(forKey key: String) -> String?
    /// 写入单个键值。返回是否确定落盘成功。
    ///
    /// **扫描状态/进度的写入必须检查返回值**：写入失败时调用方不得
    /// 声明阶段切换成功，也不得更新"已持久化进度"的内存基线，
    /// 否则崩溃恢复会读到一个从未真正保存过的中间状态。
    @discardableResult
    func setString(_ value: String?, forKey key: String) -> Bool
    /// 批量提交结果快照；生产实现必须在一个数据库事务中完成。
    /// 返回 false 表示整批没有落盘，调用方不得把结果标记为已完成。
    @discardableResult
    func setStringsAtomically(_ values: [String: String?]) -> Bool
}

extension KeyValueStore {
    @discardableResult
    func setStringsAtomically(_ values: [String: String?]) -> Bool {
        var success = true
        for (key, value) in values where !setString(value, forKey: key) {
            success = false
        }
        return success
    }
}

/// 内存字典实现。线程不安全，仅供单元测试与 SwiftUI Preview 注入，
/// 不做生产用途（生产用 GRDB 适配，任务卡 T03）。
///
/// 支持 `failingKeys` 注入：把指定键的写入强制判为失败，
/// 让"落盘失败时不得声明成功"这类事务语义能在 CI 上被直接验证。
final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: String] = [:]
    /// 这些键的写入一律返回 false（模拟磁盘满 / 事务中断）。
    var failingKeys: Set<String> = []
    /// 写入尝试次数（含失败），供测试断言"失败后没有重试写入基线"。
    private(set) var writeAttempts: [String] = []

    /// 清空写入尝试记录（测试辅助；`writeAttempts` 本身只读）。
    func resetWriteAttempts() {
        writeAttempts.removeAll()
    }

    init() {}

    init(prepopulated: [String: String]) {
        storage = prepopulated
    }

    func string(forKey key: String) -> String? {
        storage[key]
    }

    @discardableResult
    func setString(_ value: String?, forKey key: String) -> Bool {
        writeAttempts.append(key)
        guard !failingKeys.contains(key) else { return false }
        storage[key] = value
        return true
    }

    /// 原子批量：任一键失败则整批不生效（模拟事务回滚），
    /// 避免测试里出现"一半写成功"的虚假状态。
    @discardableResult
    func setStringsAtomically(_ values: [String: String?]) -> Bool {
        guard values.keys.allSatisfy({ !failingKeys.contains($0) }) else { return false }
        values.forEach { key, value in
            writeAttempts.append(key)
            storage[key] = value
        }
        return true
    }
}
