// MARK: - Theme
// 职责：深色主题色彩常量与共享样式，对齐 Daily Inbox 视觉规范。

import SwiftUI

enum Theme {

    // MARK: 背景

    /// 页面主背景渐变（深海蓝 → 近黑）。
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.07, blue: 0.14),
            Color(red: 0.03, green: 0.04, blue: 0.08),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 卡片背景色。
    static let cardBackground = Color.white.opacity(0.06)

    /// 分组区块背景色（半透明毛玻璃）。
    static let sectionBackground = Color.white.opacity(0.05)

    // MARK: 概览卡片渐变

    /// "新增"卡片渐变（蓝紫）。
    static let newAssetGradient = LinearGradient(
        colors: [
            Color(red: 0.15, green: 0.35, blue: 0.65),
            Color(red: 0.10, green: 0.22, blue: 0.50),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// "待确认"卡片渐变（深蓝）。
    static let pendingGradient = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.18, blue: 0.42),
            Color(red: 0.06, green: 0.12, blue: 0.32),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// "任务"卡片渐变（青蓝）。
    static let taskGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.28, blue: 0.38),
            Color(red: 0.05, green: 0.18, blue: 0.28),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: 功能色

    static let accentBlue = Color(red: 0.20, green: 0.55, blue: 1.0)
    static let accentOrange = Color(red: 1.0, green: 0.55, blue: 0.15)
    static let accentGreen = Color(red: 0.20, green: 0.78, blue: 0.55)
    static let accentRed = Color(red: 1.0, green: 0.30, blue: 0.30)

    // MARK: 文字

    static let titleText = Color.white
    static let subtitleText = Color.white.opacity(0.6)
    static let bodyText = Color.white.opacity(0.85)
    static let captionText = Color.white.opacity(0.45)

    // MARK: Tab Bar

    static let tabBarBackground = Color.white.opacity(0.08)
    static let tabBarIndicator = Color.white.opacity(0.15)

    // MARK: 扫描按钮渐变

    static let scanButtonGradient = LinearGradient(
        colors: [
            Color(red: 0.15, green: 0.40, blue: 0.80),
            Color(red: 0.10, green: 0.25, blue: 0.60),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: 工具

    /// 圆角常量。
    static let cornerRadius: CGFloat = 16
    static let smallCorner: CGFloat = 12
    static let cardCorner: CGFloat = 14
}
