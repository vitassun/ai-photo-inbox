// MARK: - CloudConsent / PermissionCopy
// 职责：T18 云端分析同意门闩（纯逻辑）——KeyValueStore 持久开关，默认关；
//       PRD P12 指定同意文案（逐字，测试防回退删改）；权限状态展示映射。
// 任务卡：T18。红线 4：云端候选必须去 EXIF/GPS 且首次显式同意后才允许出网。

import Foundation

enum CloudConsent {

    static let storageKey = "cloud_consent_v1"

    /// 同意文案——PRD P12 验收指定句，逐字保留（单测断言防篡改/删减）。
    static let consentNotice =
        "候选缩略图与 OCR 文本将发送至我们的服务器并转发给 AI 服务商；服务商默认最长保留约 30 天"

    /// 数据去向补充说明（同意 sheet 内第二行）。
    static let destinationNotice =
        "发送前会去除 EXIF/GPS 元数据；关闭开关后立即停止一切出网请求。"

    /// 门闩读取：键缺失/值不符一律视为未同意（保守默认，零出网）。
    static func isEnabled(store: KeyValueStore) -> Bool {
        store.string(forKey: storageKey) == "on"
    }

    /// 写入开关并返回最终状态。关闭立即生效（下次调用方读门闩即得 false）。
    @discardableResult
    static func setEnabled(_ enabled: Bool, store: KeyValueStore) -> Bool {
        store.setString(enabled ? "on" : "off", forKey: storageKey)
        return enabled
    }
}

/// 权限状态面板的展示映射（P12；5 种授权状态全覆盖，含 restricted/limited）。
enum PermissionCopy {

    struct Presentation: Equatable {
        let title: String
        let detail: String
        /// 是否提供"去系统设置"动作。
        let needsSystemSettings: Bool
    }

    static func presentation(for status: PhotoAuthorizationStatus) -> Presentation {
        switch status {
        case .notDetermined:
            return Presentation(
                title: "未授权",
                detail: "尚未请求相册权限，可在首页发起授权。",
                needsSystemSettings: false
            )
        case .authorized:
            return Presentation(
                title: "完整访问",
                detail: "可整理全部照片；删除仍需系统确认框由你批准。",
                needsSystemSettings: false
            )
        case .limited:
            return Presentation(
                title: "仅所选照片",
                detail: "只能看到你选中的照片，升级后整理建议更完整。",
                needsSystemSettings: true
            )
        case .denied:
            return Presentation(
                title: "已拒绝",
                detail: "相册功能不可用，请到系统设置开启。",
                needsSystemSettings: true
            )
        case .restricted:
            return Presentation(
                title: "受限制",
                detail: "设备策略限制了相册访问（如家长控制）。",
                needsSystemSettings: true
            )
        }
    }
}
