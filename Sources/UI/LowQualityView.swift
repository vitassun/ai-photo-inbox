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
    @State private var isDeleting = false
    @State private var statusText: String?
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

    var body: some View {
        VStack(spacing: 0) {
            if let statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            } else {
                selectedIDs.formUnion(allSuggestedIDs)
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
                        } else {
                            selectedIDs.formUnion(suggestedIDs)
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
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 单张误判移出（P6 验收）：verdict=keep + user_override，
    /// 引擎镜像同步移除；反馈记录留待 V1.5 偏好学习。
    private func moveOut(_ id: String) {
        environment.database.setDecision(
            assetId: id,
            verdict: .keep,
            reason: "user_override",
            decidedAt: Date()
        )
        selectedIDs.remove(id)
        environment.engine.removeLowQualityCandidates(assetIds: [id]) {
            DispatchQueue.main.async { reload() }
        }
    }

    private func confirmDeletion() {
        let requested = selectedIDs.sorted()
        let existingIDs = Set(environment.photoLibraryService.fetchAssets(matching: requested)
            .map(\.localIdentifier))
        let ids = requested.filter { existingIDs.contains($0) }
        guard !ids.isEmpty else {
            selectedIDs.removeAll()
            statusText = "所选照片已不在相册中。"
            reload()
            return
        }
        isDeleting = true
        statusText = "等待你在系统确认框中批准…"
        environment.photoLibraryService.requestDelete(of: ids) { success, error in
            isDeleting = false
            if success {
                environment.database.markDeleted(assetIds: ids)
                selectedIDs.removeAll()
                statusText = "已批准删除。照片将在系统\"最近删除\"保留约 30 天。"
                environment.engine.removeLowQualityCandidates(assetIds: ids) {
                    DispatchQueue.main.async {
                        onDeleted(ids)
                        reload()
                    }
                }
            } else {
                let survivors = Set(environment.photoLibraryService
                    .fetchAssets(matching: ids)
                    .map(\.localIdentifier))
                let deleted = Set(ids).subtracting(survivors)
                if !deleted.isEmpty {
                    let deletedIDs = Array(deleted)
                    environment.database.markDeleted(assetIds: deletedIDs)
                    selectedIDs.subtract(deleted)
                    statusText = "已删除 \(deleted.count) 张；其余项目未执行，可重试。"
                    environment.engine.removeLowQualityCandidates(assetIds: deletedIDs) {
                        DispatchQueue.main.async {
                            onDeleted(deletedIDs)
                            reload()
                        }
                    }
                } else {
                    statusText = "未执行删除\(error.map { "：\($0.localizedDescription)" } ?? "。")可重试。"
                    reload()
                }
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

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("完成") { onDismiss() }
                    .padding()
            }

            ZStack {
                Color(.systemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else if failed {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("无法加载图片")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil, !failed else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier], options: nil
            ).firstObject else {
                DispatchQueue.main.async { self.failed = true }
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.isSynchronous = true
            var delivered: UIImage?
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1600, height: 1600),
                contentMode: .aspectFit,
                options: options
            ) { img, _ in delivered = img }
            DispatchQueue.main.async {
                if let img = delivered {
                    self.image = img
                } else {
                    self.failed = true
                }
            }
        }
    }
}
