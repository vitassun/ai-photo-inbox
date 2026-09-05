// MARK: - SettingsView
// 职责：设置页（P12）——深色主题适配。权限状态面板、云端分析开关（默认关 + 首次
//       显式同意才可开启）、订阅管理占位、关于。红线 4：未同意前零出网。
// 任务卡：T18。

import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tabBarState: RootTabBarState

    @State private var cloudOn = false
    @State private var showConsentSheet = false
    @State private var authStatus: PhotoAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            permissionSection
            cloudSection
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
        .sheet(isPresented: $showConsentSheet) {
            ConsentSheet { granted in
                cloudOn = CloudConsent.setEnabled(granted, store: environment.store)
            }
        }
    }

    private func refreshStatus() {
        cloudOn = CloudConsent.isEnabled(store: environment.store)
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

    // MARK: 云端分析（默认关）

    private var cloudSection: some View {
        Section {
            Toggle("允许云端 AI 兜底", isOn: Binding(
                get: { cloudOn },
                set: { newValue in
                    if newValue {
                        cloudOn = false
                        showConsentSheet = true
                    } else {
                        cloudOn = CloudConsent.setEnabled(false, store: environment.store)
                    }
                }
            ))
        } header: {
            Text("云端分析")
        } footer: {
            Text("默认关闭。关闭时全部识别在本机完成，零出网请求。")
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

/// 同意确认 sheet：深色主题适配。
private struct ConsentSheet: View {
    let onDecision: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("开启云端分析前，请确认")
                    .font(.headline)
                Text(CloudConsent.consentNotice)
                    .font(.subheadline)
                Text(CloudConsent.destinationNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        onDecision(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("同意并开启") {
                        onDecision(true)
                        dismiss()
                    }
                    .bold()
                }
            }
            .navigationTitle("云端分析")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
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
