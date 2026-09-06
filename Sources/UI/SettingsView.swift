// MARK: - SettingsView
// 职责：设置页——深色主题适配。权限状态面板、订阅管理占位、关于。
// 云端 LLM 仍保留为受同意门闩保护的基础设施，但当前没有可用的产品入口，
// 因此不在设置页展示一个不会产生实际结果的开关。

import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tabBarState: RootTabBarState

    @State private var authStatus: PhotoAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            permissionSection
            subscriptionSection
            aboutSection
        }
        .navigationTitle("设置")
        .toolbar(.hidden, for: .tabBar)
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .tint(Theme.accentBlue)
        .onAppear {
            tabBarState.isHidden = true
            refreshStatus()
        }
        .onDisappear { tabBarState.isHidden = false }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshStatus() }
        }
    }

    private func refreshStatus() {
        authStatus = environment.photoLibraryService.authorizationStatus
        environment.startChangeMonitoringIfAuthorized()
    }

    // MARK: 相册权限面板

    private var permissionSection: some View {
        Section("相册权限") {
            let presentation = PermissionCopy.presentation(for: authStatus)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title).font(.subheadline.weight(.medium))
                Text(presentation.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if presentation.needsSystemSettings {
                Button("去系统设置") {
                    environment.photoLibraryService.openSystemSettings()
                }
            }
        }
        .listRowBackground(Theme.sectionBackground)
    }

    // MARK: 订阅管理（占位）与关于

    private var subscriptionSection: some View {
        Section("订阅管理") {
            Text("暂未开放")
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Theme.sectionBackground)
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledRow(label: "版本", value: appVersion)
            VStack(alignment: .leading, spacing: 4) {
                Text("隐私承诺").font(.subheadline.weight(.medium))
                Text("本地分析优先；删除必经系统确认框；收藏/编辑过的照片永不进入删除建议；空间数字永远带\"约\"。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Theme.sectionBackground)
    }

    private var appVersion: String {
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

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
