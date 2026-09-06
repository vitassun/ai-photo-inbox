// MARK: - LargeMediaView
// 职责：大媒体清理页（P7）——估算体积降序列表、"约 xx"可释放汇总、
//       iCloud 未下载折叠分组、Live Photo 明示配对删除；批量删除走系统确认框。
// 任务卡：T17。红线 3：空间数字永远带"约"；未下载资产不计入可释放汇总。

import SwiftUI

struct LargeMediaView: View {
    @ObservedObject var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tabBarState: RootTabBarState
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var candidates: [LargeMediaCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var selectionSources: [String: DeletionSelectionSource] = [:]
    @State private var isDeleting = false
    @State private var statusText: String?
    @State private var showOffloaded = false
    @State private var viewerAssetID: String?

    /// 本机可清理（locally_available）与 iCloud 未下载两组。
    private var localCandidates: [LargeMediaCandidate] {
        candidates.filter { $0.record.locallyAvailable }
    }

    private var offloadedCandidates: [LargeMediaCandidate] {
        candidates.filter { !$0.record.locallyAvailable }
    }

    private var allSuggestedIDs: Set<String> {
        Set(localCandidates.filter(\.canPreselect).map(\.record.localIdentifier))
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

    /// 勾选集的可释放估算（仅本机资产可勾选）。
    private var selectedBytes: Int64 {
        sumEstimatedBytes(localCandidates.filter {
            selectedIDs.contains($0.record.localIdentifier)
        })
    }

    private var totalLocalBytes: Int64 {
        sumEstimatedBytes(localCandidates)
    }

    private func sumEstimatedBytes(_ values: [LargeMediaCandidate]) -> Int64 {
        values.reduce(into: Int64(0)) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.estimatedBytes)
            total = overflow ? Int64.max : sum
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 无安全建议时按钮置灰，仍明确提供“全选建议”入口。
            suggestionToggle
            summaryHeader
            if let statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            if candidates.isEmpty {
                ContentUnavailableView(
                    "没有占空间的大文件",
                    systemImage: "checkmark.seal",
                    description: Text("扫描完成后，超过约 200MB 的视频/照片会出现在这里")
                )
                listSpacer
            } else {
                mediaList
                deleteBar
            }
        }
        .navigationTitle("大媒体清理")
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

    private var listSpacer: some View { Spacer(minLength: 0) }

    private var summaryHeader: some View {
        VStack(spacing: 4) {
            Text(selectedIDs.isEmpty
                 ? "本机共发现 \(localCandidates.count) 个大文件，约 \(MediaSizeEstimator.displayBytes(totalLocalBytes))"
                 : "已勾选 \(selectedIDs.count) 项，约可释放 \(MediaSizeEstimator.displayBytes(selectedBytes))")
                .font(.subheadline.weight(.medium))
            Text("体积为按分辨率/时长的估算值，仅供参考")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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

    private var mediaList: some View {
        List {
            Section {
                ForEach(localCandidates, id: \.record.localIdentifier) { candidate in
                    row(candidate)
                }
            }

            if !offloadedCandidates.isEmpty {
                Section {
                    if showOffloaded {
                        ForEach(offloadedCandidates, id: \.record.localIdentifier) { candidate in
                            row(candidate, selectable: false)
                        }
                    }
                } header: {
                    Button {
                        showOffloaded.toggle()
                    } label: {
                        HStack {
                            Image(systemName: showOffloaded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text("iCloud 未下载 \(offloadedCandidates.count) 项 · 不计入可释放估算")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ candidate: LargeMediaCandidate, selectable: Bool = true) -> some View {
        let id = candidate.record.localIdentifier
        let selected = selectedIDs.contains(id)

        return HStack(spacing: 12) {
            AssetThumbnailView(side: 52, localIdentifier: id)
                .onTapGesture {
                    viewerAssetID = id
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(mediaTitle(candidate)).font(.subheadline.weight(.medium))
                if candidate.record.isLivePhoto {
                    Text("含配对视频组件，将一并删除")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if !candidate.record.locallyAvailable {
                    Text("iCloud 未下载").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("约 \(MediaSizeEstimator.displayBytes(candidate.estimatedBytes))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            if selectable {
                Button {
                    toggleSelection(id)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? .red : .gray)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func mediaTitle(_ candidate: LargeMediaCandidate) -> String {
        let record = candidate.record
        switch record.mediaType {
        case .video:
            let duration = record.duration.isFinite
                ? min(max(record.duration, 0), AppConfig.videoDurationCapSeconds)
                : 0
            let minutes = Int(duration / 60)
            return duration >= 60 ? "视频 · \(minutes) 分钟" : "视频 · \(Int(duration)) 秒"
        default:
            return record.isLivePhoto ? "Live Photo" : "照片"
        }
    }

    private var deleteBar: some View {
        Button {
            confirmDeletion()
        } label: {
            Text(selectedIDs.isEmpty
                 ? "勾选要删除的项目"
                 : "进入系统确认框，删除 \(selectedIDs.count) 项")
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
        candidates = environment.engine.largeMediaCandidates
        // 进入页面只展示候选，不替用户做删除选择；刷新时也清掉已离开列表的旧勾选。
        let validIDs = Set(candidates.filter { $0.record.locallyAvailable }
            .map(\.record.localIdentifier))
        selectedIDs.formIntersection(validIDs)
        selectionSources = selectionSources.filter { validIDs.contains($0.key) }
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
                environment.engine.purgeDeletedFromViews(assetIds: Array(approved)) {
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
                statusText = "已批准删除。项目将在系统\"最近删除\"保留约 30 天。"
            }
        }
    }
}
