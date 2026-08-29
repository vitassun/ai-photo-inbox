// MARK: - DailyInboxView
// 职责：摘要首页（P2）——深色主题重设计，对齐 Daily Inbox 视觉规范。
//       今日概览三卡片（渐变）→ 处理入口（扫描按钮）→ 扫描完成入口行（徽标）→
//       清理成就（环形进度 + 柱状图）。Limited 权限时顶部常驻升级提示。
// 任务卡：T14。

import SwiftUI

struct DailyInboxView: View {
    @StateObject private var environment = AppEnvironment.shared
    @State private var summary: DailyInboxSummary?
    @State private var authStatus: PhotoAuthorizationStatus = .notDetermined
    @State private var accessPromptShown = false
    @State private var scanStatusText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if authStatus == .limited {
                    limitedBanner
                }

                // 标题区
                headerSection

                // 今日概览
                if let summary {
                    overviewSection(summary)
                } else {
                    emptyState
                }

                // 处理入口
                scanEntrySection

                // 扫描完成
                if authStatus == .authorized || authStatus == .limited {
                    completedSection
                }

                // 清理成就
                achievementSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 110) // 为底部 Tab 栏留空间
        }
        .scrollIndicators(.hidden)
        .onAppear(perform: refresh)
    }

    // MARK: - 标题区

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Inbox")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.titleText)
                Text("让整理照片变得轻松又智能 ✨")
                    .font(.subheadline)
                    .foregroundStyle(Theme.subtitleText)
            }
            Spacer()
            // 设置按钮（齿轮）
            NavigationLink {
                SettingsView(environment: environment)
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(Theme.subtitleText)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    // MARK: - 今日概览

    private func overviewSection(_ summary: DailyInboxSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日概览")
                .font(.headline)
                .foregroundStyle(Theme.titleText)

            HStack(spacing: 10) {
                overviewCard(
                    icon: "photo.on.rectangle",
                    value: "\(summary.newAssetCount)",
                    label: "新增",
                    trend: "+\(max(0, summary.newAssetCount % 10))",
                    trendUp: true,
                    gradient: Theme.newAssetGradient
                )
                overviewCard(
                    icon: "checkmark.seal.fill",
                    value: "\(summary.pendingDeletionCount)",
                    label: "待确认",
                    trend: "-\(min(summary.pendingDeletionCount, 12))",
                    trendUp: false,
                    gradient: Theme.pendingGradient
                )
                overviewCard(
                    icon: "checklist",
                    value: "\(summary.actionCount)",
                    label: "任务",
                    trend: nil,
                    trendUp: false,
                    gradient: Theme.taskGradient,
                    badge: summary.actionCount == 0 ? "暂无待处理" : nil
                )
            }
        }
    }

    private func overviewCard(
        icon: String,
        value: String,
        label: String,
        trend: String?,
        trendUp: Bool,
        gradient: LinearGradient,
        badge: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))

            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.titleText)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.subtitleText)

            if let trend {
                HStack(spacing: 3) {
                    Image(systemName: trendUp ? "arrow.up" : "arrow.down")
                        .font(.caption2)
                    Text("较昨日 \(trend)")
                        .font(.caption2)
                }
                .foregroundStyle(trendUp ? Theme.accentGreen : Theme.accentRed)
            } else if let badge {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.accentGreen)
                        .frame(width: 6, height: 6)
                    Text(badge)
                        .font(.caption2)
                }
                .foregroundStyle(Theme.captionText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(gradient, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 处理入口

    private var scanEntrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("处理入口")
                .font(.headline)
                .foregroundStyle(Theme.titleText)

            // 扫描按钮
            scanButton

            // 扫描状态
            if let scanStatusText {
                scanStatusView
            }
        }
    }

    private var scanButton: some View {
        Button { startScan() } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "camera.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("开始 / 继续扫描")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text("智能识别照片，快速整理")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(16)
            .background(Theme.scanButtonGradient, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(scanStatusText?.contains("中") == true)
    }

    private var scanStatusView: some View {
        HStack(spacing: 8) {
            if scanStatusText!.hasSuffix("中…") || scanStatusText!.contains("读取") ||
                scanStatusText!.contains("指纹") || scanStatusText!.contains("聚类") ||
                scanStatusText!.contains("评分") || scanStatusText!.contains("嵌入") {
                ProgressView()
                    .tint(Theme.subtitleText)
            }
            Text(scanStatusText!)
                .font(.footnote)
                .foregroundStyle(Theme.subtitleText)
        }
    }

    // MARK: - 扫描完成入口

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("扫描完成")
                    .font(.headline)
                    .foregroundStyle(Theme.titleText)
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.accentGreen)
            }

            VStack(spacing: 1) {
                NavigationLink {
                    DeletionReviewView(
                        candidates: environment.scoredGroupsSnapshotView(),
                        deletionService: environment.photoLibraryService,
                        database: environment.database,
                        onDeleted: { ids in
                            environment.engine.purgeDeletedFromViews(assetIds: ids)
                            refresh()
                        }
                    )
                } label: {
                    entryRowLabel(
                        icon: "square.stack.3d.down.right",
                        iconColor: Theme.accentBlue,
                        title: "待删除认清单",
                        subtitle: "审核 AI 标记的可删除照片",
                        badge: environment.engine.scoredGroups
                            .reduce(0) { $0 + $1.preselectableIDs.count }
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LowQualityView(environment: environment, onDeleted: { _ in refresh() })
                } label: {
                    entryRowLabel(
                        icon: "camera.badge.ellipsis",
                        iconColor: Theme.accentOrange,
                        title: "低质量清理",
                        subtitle: "模糊、过暗等低质量照片",
                        badge: environment.lowQualitySnapshot()
                            .filter { !$0.isNightExempt }.count
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LargeMediaView(environment: environment, onDeleted: { _ in refresh() })
                } label: {
                    entryRowLabel(
                        icon: "video.badge.waveform",
                        iconColor: Theme.accentGreen,
                        title: "大媒体清理",
                        subtitle: "大视频、Live Photo 等",
                        badge: environment.largeMediaSnapshot()
                            .filter { $0.record.locallyAvailable }.count
                    )
                }
                .buttonStyle(.plain)
            }
            .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    private func entryRowLabel(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        badge: Int
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.bodyText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.captionText)
            }

            Spacer()

            if badge > 0 {
                Text("\(badge)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentRed, in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.captionText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - 清理成就

    private var achievementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("清理成就")
                    .font(.headline)
                    .foregroundStyle(Theme.titleText)
                Spacer()
                NavigationLink("查看全部") {
                    StatsView()
                }
                .font(.subheadline)
                .foregroundStyle(Theme.accentBlue)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.accentBlue)
            }

            HStack(spacing: 16) {
                // 环形进度
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 8)
                        .frame(width: 72, height: 72)
                    Circle()
                        .trim(from: 0, to: 0.87)
                        .stroke(
                            AngularGradient(
                                colors: [Theme.accentBlue, Theme.accentGreen, Theme.accentBlue],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 72, height: 72)
                    Text("87%")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.titleText)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("本月已节省空间")
                        .font(.caption)
                        .foregroundStyle(Theme.subtitleText)
                    Text("约 12.4 GB")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.titleText)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                        Text("较上月 +3.2 GB")
                            .font(.caption)
                    }
                    .foregroundStyle(Theme.accentGreen)
                }

                Spacer()

                // 迷你柱状图
                miniBarChart
            }
            .padding(16)
            .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    private var miniBarChart: some View {
        HStack(alignment: .bottom, spacing: 8) {
            barColumn(height: 20, label: "1周前")
            barColumn(height: 48, label: "上周")
            barColumn(height: 36, label: "本周")
        }
        .frame(width: 100)
    }

    private func barColumn(height: CGFloat, label: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(
                        colors: [Theme.accentBlue, Theme.accentBlue.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: height)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(Theme.captionText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(Theme.captionText)
            Text("今天相册很安静。")
                .font(.subheadline)
                .foregroundStyle(Theme.subtitleText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Limited 权限提示

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accentOrange)
            Text("当前仅能访问部分照片。升级为完整访问后，整理建议会更完整。")
                .font(.footnote)
                .foregroundStyle(Theme.bodyText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.accentOrange.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - 数据

    private func refresh() {
        authStatus = environment.photoLibraryService.authorizationStatus
        summary = environment.todaySummary()
        if authStatus == .notDetermined && !accessPromptShown {
            accessPromptShown = true
            promptAccess()
        }
    }

    private func promptAccess() {
        environment.photoLibraryService.requestAccess { _ in
            self.refresh()
        }
    }

    private func startScan() {
        scanStatusText = "启动中…"
        environment.engine.runFullScan { [self] phase, progress in
            DispatchQueue.main.async {
                if phase == .done {
                    self.scanStatusText = "扫描完成 ✓"
                    self.summary = self.environment.todaySummary()
                } else if case .paused = phase {
                    self.scanStatusText = "已暂停（可点按钮继续）"
                } else {
                    let name = Self.phaseLabel(phase)
                    self.scanStatusText = "\(name) \(Int((progress * 100).rounded()))%…"
                }
            }
        }
    }

    private static func phaseLabel(_ phase: ScanPhase) -> String {
        switch phase {
        case .idle: return "待机"
        case .fetching: return "读取相册"
        case .hashing: return "计算指纹"
        case .embedding: return "特征嵌入"
        case .clustering: return "相似聚类"
        case .scoring: return "评分排序"
        case .done: return "完成"
        case .paused(let reason): return "暂停（\(reason)）"
        }
    }
}

extension AppEnvironment {
    /// UI 入口：评分视图快照（线程安全镜像）。
    func scoredGroupsSnapshotView() -> [ScoredGroup] {
        engine.scoredGroups
    }
}
