// MARK: - LowQualityView
// 职责：低质量批量页（P6）——模糊/过曝/欠曝三分区网格、夜景豁免角标折叠区、
//       长按移出（user_override 反馈）、批量删除走系统确认框。
// 任务卡：T16。红线 6：豁免项永不进预选集合；删除必经系统确认框。

import SwiftUI
import Photos

struct LowQualityView: View {
    @ObservedObject var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tabBarState: RootTabBarState
    /// 删除完成回调（首页刷新摘要）。
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var candidates: [LowQualityCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var selectionSources: [String: DeletionSelectionSource] = [:]
    @State private var isDeleting = false
    @State private var statusText: String?
    @State private var undoKeepID: String?
    @State private var showExempted = false
    @State private var viewerAssetID: String?

    private var exempted: [LowQualityCandidate] {
        candidates.filter(\.isNightExempt)
    }

    private var actionable: [LowQualityCandidate] {
        candidates.filter { !$0.isNightExempt }
    }

    private var allSuggestedIDs: Set<String> {
        Set(actionable.filter(\.canPreselect).map(\.record.localIdentifier))
    }

    private var allSuggestedSelected: Bool {
        !allSuggestedIDs.isEmpty && allSuggestedIDs.allSatisfy { selectedIDs.contains($0) }
    }

    private var deletionCoordinator: DeletionCoordinator {
        DeletionCoordinator(
            photoLibrary: environment.photoLibraryService,
            database: environment.database
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let statusText {
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if undoKeepID != nil {
                        Button("撤销保留") { undoKeep() }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(8)
            }
            // 无安全建议时按钮置灰，仍明确提供“全选建议”入口。
            suggestionToggle
            if actionable.isEmpty && exempted.isEmpty {
                ContentUnavailableView(
                    "没有低质量照片",
                    systemImage: "checkmark.seal",
                    description: Text("扫描完成后，模糊/曝光异常的照片会出现在这里")
                )
            } else {
                gridList
                deleteBar
            }
        }
        .navigationTitle("低质量清理")
        .toolbar(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .onAppear {
            tabBarState.isHidden = true
            reload()
        }
        .onDisappear { tabBarState.isHidden = false }
        .onChange(of: scenePhase) { phase in
            if phase == .active { reload() }
        }
        .onChange(of: environment.libraryRevision) { _ in
            reload()
        }
        .fullScreenCover(item: Binding(
            get: { viewerAssetID.map { SingleAssetViewerContext(id: $0) } },
            set: { viewerAssetID = $0?.id }
        )) { context in
            SinglePhotoViewer(localIdentifier: context.id) {
                viewerAssetID = nil
            }
        }
    }

    private var suggestionToggle: some View {
        Button(allSuggestedSelected ? "取消全选" : "全选建议") {
            if allSuggestedSelected {
                selectedIDs.subtract(allSuggestedIDs)
                allSuggestedIDs.forEach { selectionSources[$0] = nil }
            } else {
                selectedIDs.formUnion(allSuggestedIDs)
                allSuggestedIDs.forEach { selectionSources[$0] = .suggestion }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .disabled(allSuggestedIDs.isEmpty)
    }

    private var gridList: some View {
        List {
            kindSection(.blurry, title: "模糊")
            kindSection(.overexposed, title: "过曝")
            kindSection(.underexposed, title: "欠曝")

            // 夜景豁免（红线 6）：可见但不进预选集合。
            if !exempted.isEmpty {
                Section {
                    if showExempted {
                        grid(exempted, selectable: false)
                    }
                } header: {
                    Button {
                        showExempted.toggle()
                    } label: {
                        HStack {
                            Image(systemName: showExempted ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text("夜景豁免 \(exempted.count) 张 · 不推荐删除")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func kindSection(_ kind: LowQualityKind, title: String) -> some View {
        let rows = actionable.filter { $0.kind == kind }
        if !rows.isEmpty {
            let suggestedIDs = rows.filter(\.canPreselect)
                .map { $0.record.localIdentifier }
            let allSelected = !suggestedIDs.isEmpty
                && suggestedIDs.allSatisfy { selectedIDs.contains($0) }
            Section {
                grid(rows, selectable: true)
            } header: {
                HStack {
                    Text("\(title) · \(rows.count) 张")
                    Spacer()
                    Button(allSelected ? "取消全选" : "全选建议") {
                        if allSelected {
                            selectedIDs.subtract(suggestedIDs)
                            suggestedIDs.forEach { selectionSources[$0] = nil }
                        } else {
                            selectedIDs.formUnion(suggestedIDs)
                            suggestedIDs.forEach { selectionSources[$0] = .suggestion }
                        }
                    }
                    .font(.caption)
                    .disabled(suggestedIDs.isEmpty)
                }
            }
        }
    }

    private func grid(_ rows: [LowQualityCandidate], selectable: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(rows, id: \.record.localIdentifier) { candidate in
                cell(candidate, selectable: selectable)
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ candidate: LowQualityCandidate, selectable: Bool) -> some View {
        let id = candidate.record.localIdentifier
        let selected = selectedIDs.contains(id)

        return VStack(spacing: 4) {
            ZStack {
                // 图片区：点缩略图本体 → 开全屏查看原图。
                AssetThumbnailView(side: 84, localIdentifier: id)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { viewerAssetID = id }

                // 红色边框：选中态外圈。
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.red : Color.clear, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if selectable {
                    // 右下角勾选圆钮：独立点击目标，不被 onTapGesture 吞掉。
                    Button { toggleSelection(id) } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? .red : .gray)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.borderless)  // 独立触控目标，确保不被上层 onTapGesture 拦截
                    .padding(4)
                    .accessibilityLabel(selected ? "取消选择低质量照片" : "选择低质量照片")
                    .accessibilityValue(selected ? "已选中" : "未选中")
                } else {
                    Image(systemName: "moon.stars.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .allowsHitTesting(false)
                }
            }
            .contextMenu {
                if selectable {
                    Button("不是低质量，移出候选") { moveOut(id) }
                }
            }

            Text(kindLabel(candidate))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func kindLabel(_ candidate: LowQualityCandidate) -> String {
        switch candidate.kind {
        case .blurry: return "模糊"
        case .overexposed: return "过曝"
        case .underexposed: return "欠曝"
        }
    }

    private var deleteBar: some View {
        Button {
            confirmDeletion()
        } label: {
            Text(selectedIDs.isEmpty
                 ? "勾选要删除的照片"
                 : "进入系统确认框，删除 \(selectedIDs.count) 张")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedIDs.isEmpty || isDeleting)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: 动作

    private func reload() {
        let next = environment.engine.lowQualityCandidates
        candidates = next
        selectedIDs.formIntersection(Set(next.filter { !$0.isNightExempt }
            .map(\.record.localIdentifier)))
        let visibleIDs = Set(next.map { $0.record.localIdentifier })
        selectionSources = selectionSources.filter { visibleIDs.contains($0.key) }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            selectionSources[id] = nil
        } else {
            selectedIDs.insert(id)
            selectionSources[id] = .user
        }
    }

    /// 单张误判移出（P6 验收）：verdict=keep + user_override，
    /// 引擎镜像同步移除；反馈记录留待 V1.5 偏好学习。
    private func moveOut(_ id: String) {
        let saved = environment.database.setDecision(
            assetId: id,
            verdict: .keep,
            reason: "user_override",
            decidedAt: Date()
        )
        guard saved else {
            statusText = "保留操作未保存，请检查存储空间后重试。"
            return
        }
        undoKeepID = id
        selectedIDs.remove(id)
        selectionSources[id] = nil
        environment.engine.removeLowQualityCandidates(assetIds: [id]) {
            DispatchQueue.main.async { reload() }
        }
    }

    private func undoKeep() {
        guard let id = undoKeepID else { return }
        guard environment.database.removeDecision(assetId: id) else {
            statusText = "撤销保留未保存，请检查存储空间后重试。"
            return
        }
        undoKeepID = nil
        statusText = "已撤销保留；下一次扫描会重新评估这张照片。"
    }

    private func confirmDeletion() {
        isDeleting = true
        statusText = "正在复核最新相册状态…"
        let selections = selectedIDs.sorted().map { id in
            DeletionSelection(assetID: id, source: selectionSources[id] ?? .user)
        }
        deletionCoordinator.execute(selections: selections, groups: []) { preflight, result in
            let approved = Set(result?.approvedIDs ?? [])
            var auditSaved = true
            if !approved.isEmpty {
                auditSaved = environment.database.markDeleted(assetIds: Array(approved))
                selectedIDs.subtract(approved)
                approved.forEach { selectionSources[$0] = nil }
                environment.engine.removeLowQualityCandidates(assetIds: Array(approved)) {
                    DispatchQueue.main.async {
                        onDeleted(Array(approved))
                        reload()
                    }
                }
            }
            isDeleting = false
            if !auditSaved {
                statusText = "系统已批准删除，但本地记录保存失败；请检查存储空间后重试。"
            } else if !preflight.safetyDataAvailable {
                statusText = "无法读取保留记录，未提交任何删除。"
            } else if let result, result.cancelled {
                statusText = "已记录此前批准的项目；系统确认被取消，后续批次未执行。"
            } else if let result, result.hasFailure {
                statusText = "已记录此前批准的项目；后续批次失败，可重试未完成项目。"
            } else if !preflight.blocked.isEmpty {
                statusText = "部分选择已撤销：\(preflight.blocked.map { "\($0.assetID)：\($0.reason.rawValue)" }.joined(separator: "、"))"
            } else if approved.isEmpty {
                statusText = "没有仍符合安全条件的选择。"
            } else {
                statusText = "已批准删除。照片将在系统\"最近删除\"保留约 30 天。"
            }
        }
    }
}

/// 单张图片查看器上下文
struct SingleAssetViewerContext: Identifiable {
    let id: String
}

/// 单张图片全屏查看器
struct SinglePhotoViewer: View {
    let localIdentifier: String
    let onDismiss: () -> Void
    var mediaType: AssetMediaType = .image
    var isLivePhoto = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("完成") { onDismiss() }
                    .padding()
            }

            MediaPreviewView(
                localIdentifier: localIdentifier,
                mediaType: mediaType,
                isLivePhoto: isLivePhoto
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
    }
}
