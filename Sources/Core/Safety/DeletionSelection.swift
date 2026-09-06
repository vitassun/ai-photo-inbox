// MARK: - DeletionSelection
// 用户逐张选择与算法建议必须保留来源，删除前协调器据此采用不同的
// 安全校验；两者最终都要经过 PhotoKit 系统确认框。

import Foundation

enum DeletionSelectionSource: String, Codable, Equatable {
    case user
    case suggestion
}

struct DeletionSelection: Codable, Equatable {
    let assetID: String
    let source: DeletionSelectionSource
}

struct DeletionPreflightIssue: Codable, Equatable {
    let assetID: String
    let source: DeletionSelectionSource
    let reason: SuggestionBlockReason
}

struct DeletionPreflightResult: Codable, Equatable {
    let approvedIDs: [String]
    let blocked: [DeletionPreflightIssue]
    let safetyDataAvailable: Bool

    var isEmpty: Bool { approvedIDs.isEmpty && blocked.isEmpty }
}
