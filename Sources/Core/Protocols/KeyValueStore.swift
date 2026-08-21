// MARK: - KeyValueStore
// 职责：键值持久化抽象。生产实现落 GRDB/UserDefaults（T03 适配），
//       单元测试注入 InMemoryKeyValueStore —— 状态机因此可在 CI 上验证断点续扫。
// 任务卡：T03 / T07。

import Foundation

/// 最小键值接口：只暴露字符串读写，序列化职责在调用方（保持协议面最小）。
/// 约定：setString 传 nil 等价于删除该键。
protocol KeyValueStore {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

/// 内存字典实现。线程不安全，仅供单元测试与 SwiftUI Preview 注入，
/// 不做生产用途（生产用 GRDB 适配，任务卡 T03）。
final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: String] = [:]

    init() {}

    init(prepopulated: [String: String]) {
        storage = prepopulated
    }

    func string(forKey key: String) -> String? {
        storage[key]
    }

    func setString(_ value: String?, forKey key: String) {
        storage[key] = value
    }
}
