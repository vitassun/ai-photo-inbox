// MARK: - SafetyRules
// 职责：删除安全红线——硬编码常量 + 预选判定函数。纯逻辑，零框架依赖。
// 任务卡：T10（安全红线）。改动本文件前必须重读 docs/feasibility-report.md §2.7 与产品红线。
//
// 三条铁律（任何代码路径、任何未来重构都不得绕过）：
//   1. 收藏过的资产永不预选删除；
//   2. 用户编辑过的资产永不预选删除；
//   3. 组内唯一（无相似替代）的资产永不预选删除。
// 第四条铁律：本 App 永不静默删除——所有删除必须经
//   PHPhotoLibrary.performChanges 触发系统确认框，由用户逐次批准。

import Foundation

/// 自动建议被安全层拒绝的原因。原因会沿着删除预检传到 UI，避免把
/// “没有建议”误解成扫描失败，也避免为了展示解释而重新读取敏感数据。
enum SuggestionBlockReason: String, Codable, Equatable {
    case favorite
    case edited
    case onlyAsset
    case userKept
    case missingFeature
    case noDirectReplacement
    case unsupportedDynamicMedia
    case unavailable
    case safetyDataUnavailable
}

enum SafetyRules {
    // MARK: 硬编码红线常量（永不参数化、永不提供开关）

    /// 收藏过的资产：任何情况下不得进入预删除集合。
    static let neverDeleteFavorites = true
    /// 用户编辑过的资产：任何情况下不得进入预删除集合。
    static let neverDeleteEdited = true
    /// 组内唯一（没有相似替代）的资产：不得预选删除。
    static let neverDeleteOnlyInGroup = true
    /// 本 App 永远不允许"静默删除"。此常量仅作文档性断言，
    /// 供 code review / CI 脚本检索；不存在任何将其置 true 的合法理由。
    static let silentDeleteAllowed = false

    // MARK: 预选判定

    /// 判定某资产是否允许进入"预选删除"名单。
    /// 注意语义：预选 ≠ 删除。预选只是把它摆进待确认清单，
    /// 真正删除永远要过 PHPhotoLibrary.performChanges 的系统确认框（T10）。
    /// - Parameters:
    ///   - asset: 资产快照。
    ///   - groupSize: 该资产所在候选组的成员数。
    ///   - isOnlyInGroup: 显式覆盖位——即使 groupSize > 1，若按更细维度
    ///     （如人脸/场景）判断该资产没有相似替代，也必须传 true。
    static func canPreselectDelete(asset: AssetRecord, groupSize: Int, isOnlyInGroup: Bool) -> Bool {
        // 红线 1：收藏 → 永不预选。
        if SafetyRules.neverDeleteFavorites && asset.favorite { return false }
        // 红线 2：编辑过 → 永不预选。
        if SafetyRules.neverDeleteEdited && asset.isEdited { return false }
        // 红线 3a：组内只有它自己（或空组异常）→ 无替代品，永不预选。
        if SafetyRules.neverDeleteOnlyInGroup && groupSize <= 1 { return false }
        // 红线 3b：显式"组内唯一"标记 → 永不预选。
        if SafetyRules.neverDeleteOnlyInGroup && isOnlyInGroup { return false }
        // 静态封面不足以证明视频或 Live Photo 的动态内容相同；本轮只允许
        // 展示和用户手动选择，不生成自动删除建议。
        if asset.mediaType == .video || asset.isLivePhoto { return false }
        return true
    }

    /// 用户手动提交前也必须重新尊重收藏、编辑和 keep 保护。
    /// 动态媒体可以手动删除，因此这里不复用自动建议的媒体限制。
    static func canUserRequestDelete(asset: AssetRecord, userKept: Bool) -> Bool {
        !asset.favorite && !asset.isEdited && !userKept
    }

    /// 对整个候选组做过滤：返回组内允许预选删除的成员（保持原有时间顺序）。
    static func preselectableMembers(in group: CandidateGroup) -> [AssetRecord] {
        let size = group.count
        return group.members.filter { member in
            canPreselectDelete(asset: member, groupSize: size, isOnlyInGroup: size <= 1)
        }
    }

    // MARK: 注释性断言

    /// 钉死红线常量未被篡改。Debug 构建下若有人改了常量会直接崩在启动期；
    /// Release 下 assert 编译剔除，零开销。建议在 AppDelegate/App 启动时调用一次。
    static func validateRedLines() {
        assert(!silentDeleteAllowed, "红线被破坏：silentDeleteAllowed 不允许为 true")
        assert(neverDeleteFavorites, "红线被破坏：neverDeleteFavorites 不允许为 false")
        assert(neverDeleteEdited, "红线被破坏：neverDeleteEdited 不允许为 false")
        assert(neverDeleteOnlyInGroup, "红线被破坏：neverDeleteOnlyInGroup 不允许为 false")
    }
}
