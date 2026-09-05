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
                SettingsView(environment: environment)
            }
            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
            menuRow(icon: "info.circle", title: "关于", color: Theme.accentBlue) {
                AboutView()
            }
        }
        .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func menuRow<Destination: View>(
        icon: String,
        title: String,
        color: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
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

private struct AboutView: View {
    @EnvironmentObject private var tabBarState: RootTabBarState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("照片整理助手")
                    .font(.title2.bold())
                Text("本地分析优先，删除必须经过系统确认框。收藏或编辑过的照片不会进入删除建议。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Divider()
                LabeledContent("版本", value: version)
                LabeledContent("隐私", value: "照片与 EXIF 默认只在本机处理")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("关于")
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .onAppear { tabBarState.isHidden = true }
        .onDisappear { tabBarState.isHidden = false }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        default: return "未知"
        }
    }
}
