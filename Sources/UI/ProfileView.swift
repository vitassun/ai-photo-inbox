// MARK: - ProfileView
// 职责：我的页面占位（底部 Tab 之一）。展示头像、设置入口、关于。
//        后续任务卡填充订阅管理等真实数据。

import SwiftUI

struct ProfileView: View {
    let environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 头像区域
                    profileHeader

                    // 功能列表
                    menuSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("我的")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accentBlue.opacity(0.3))
                    .frame(width: 80, height: 80)
                Image(systemName: "person.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accentBlue)
            }

            Text("照片整理助手")
                .font(.headline)
                .foregroundStyle(Theme.titleText)
            Text("让整理照片变得轻松又智能 ✨")
                .font(.caption)
                .foregroundStyle(Theme.subtitleText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var menuSection: some View {
        VStack(spacing: 0) {
            menuRow(icon: "gearshape", title: "设置", color: .gray) {
                // NavigationLink to SettingsView handled by parent
            }
            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
            menuRow(icon: "bell", title: "通知设置", color: Theme.accentOrange) {}
            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
            menuRow(icon: "questionmark.circle", title: "帮助与反馈", color: Theme.accentGreen) {}
            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
            menuRow(icon: "info.circle", title: "关于", color: Theme.accentBlue) {}
        }
        .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func menuRow(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(width: 28)

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.bodyText)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.captionText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}
