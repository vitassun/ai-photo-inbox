// MARK: - GRDBKeyValueStore
// 职责：KeyValueStore 协议的生产实现（scan_state 表为后端）。
//       内存实现 InMemoryKeyValueStore 只留给测试与 Preview，不进生产链路。
// 任务卡：T03。

import Foundation

final class GRDBKeyValueStore: KeyValueStore {

    private let database: PhotoLibraryDatabase

    init(database: PhotoLibraryDatabase) {
        self.database = database
    }

    func string(forKey key: String) -> String? {
        database.keyValue(forKey: key)
    }

    func setString(_ value: String?, forKey key: String) {
        database.setKeyValue(value, forKey: key)
    }

    @discardableResult
    func setStringsAtomically(_ values: [String: String?]) -> Bool {
        database.setKeyValuesAtomically(values)
    }
}
