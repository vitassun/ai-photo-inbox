// MARK: - DailyInboxView
// 职责：摘要首页（P2）——打开即见今日概览，数据来自本地库（≤1 秒可见）；
//       待删确认 / 任务动作入口；Limited 权限时顶部常驻升级提示。
// 任务卡：T14。

import SwiftUI

struct DailyInboxView: View {
    @StateObject private var environment = AppEnvironment.shared
    @State private var summary: DailyInboxSummary?
    @State private var authStatus: PhotoAuthorizationStatus = .notDetermined
    @State private var accessPromptShown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if authStatus == .limited {
                        limitedBanner
                    }
                    if let summary {
                        summarySection(summary)
                    } else {
                        // 空态文案而非空白页（P2 验收）。
                        Text("今天相册很安静。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    entriesSection
                }
                .padding()
            }
            .navigationTitle("Daily Inbox")
            .onAppear(perform: refresh)
        }
    }

    private var limitedBanner: some View {
        Text("当前仅能访问部分照片。升级为完整访问后，整理建议会更完整。（设置 → 本 App → 照片）")
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summarySection(_ summary: DailyInboxSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日概览").font(.headline)
            HStack(spacing: 12) {
                statCard("新增", "\(summary.newAssetCount)", "photo.on.rectangle")
                statCard("待确认", "\(summary.pendingDeletionCount)", "checkmark.seal")
                statCard("任务", "\(summary.actionCount)", "checklist")
            }
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("处理入口").font(.headline)

            switch authStatus {
            case .authorized, .limited:
                Button("开始 / 继续扫描") {
                    environment.engine.runFullScan { _, _ in }
                }
                .buttonStyle(.bordered)
            case .notDetermined:
                Button("授权相册访问，开始整理") { promptAccess() }
                    .buttonStyle(.borderedProminent)
            case .denied, .restricted:
                Button("相册权限被拒绝，去系统设置开启") {
                    environment.photoLibraryService.openSystemSettings()
                }
                .buttonStyle(.bordered)
            }

            if authStatus == .authorized || authStatus == .limited {
                NavigationLink("待删确认清单") {
                    DeletionReviewView(
                        candidates: environment.scoredGroupsSnapshotView(),
                        deletionService: environment.photoLibraryService,
                        database: environment.database,
                        onDeleted: { ids in
                            environment.engine.purgeDeletedFromViews(assetIds: ids)
                            refresh()
                        }
                    )
                }
            }
        }
    }

    private func statCard(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refresh() {
        authStatus = environment.photoLibraryService.authorizationStatus
        summary = environment.todaySummary()
        // 首启即请求授权（T02：notDetermined 弹窗）——不能等用户找按钮，
        // 否则未决定状态下扫描入口被挡住，弹窗永远无人触发。
        if authStatus == .notDetermined && !accessPromptShown {
            accessPromptShown = true
            promptAccess()
        }
    }

    private func promptAccess() {
        environment.photoLibraryService.requestAccess { [weak self] _ in
            // 回调已在主线程（实现方保证）；授权完成后整页状态刷新。
            self?.refresh()
        }
    }
}

extension AppEnvironment {
    /// UI 入口：评分视图快照（线程安全镜像）。
    func scoredGroupsSnapshotView() -> [ScoredGroup] {
        engine.scoredGroups
    }
}
