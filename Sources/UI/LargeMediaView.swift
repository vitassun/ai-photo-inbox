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
    @State private var undoKeepID: String?
    @State private var showOffloaded = false
    @State private var showUnknown = false
    @State private var isReprobing: Set<String> = []
    @State private var viewerAssetID: String?

    /// 本机能确认元件的候选（含 available 与 unknown 中已确认可预览者）。
    /// 可勾选、计入可释放估算的**只有** `.available`——见 allSuggestedIDs 与
    /// sumEstimatedBytes 的过滤条件。
    private var localCandidates: [LargeMediaCandidate] {
        candidates.filter { $0.record.localAvailability != .notDownloaded }
    }

    private var offloadedCandidates: [LargeMediaCandidate] {
        candidates.filter { $0.record.localAvailability == .notDownloaded }
    }

    /// 状态未知：探测还没给出结论。**不能**混进"iCloud 未下载"里，
    /// 否则用户会误以为原件在云端，而实际可能只是探测未完成。
    private var unknownCandidates: [LargeMediaCandidate] {
        candidates.filter { $0.record.localAvailability == .unknown }
    }

    /// 可安全预选 / 可勾选 / 计入可释放估算的候选。
    /// 只有明确 `.available` 的资产才满足；unknown 一律排除（红线 3）。
    private var confirmedLocalCandidates: [LargeMediaCandidate] {
        candidates.filter { $0.record.localAvailability == .available }
    }

    private var allSuggestedIDs: Set<String> {
        Set(confirmedLocalCandidates.filter(\.canPreselect).map(\.record.localIdentifier))
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

    /// 勾选集的可释放估算。只统计**已确认原件在本机**的资产：
    /// unknown 与 notDownloaded 都不计入，避免虚报可释放空间（红线 3）。
    private var selectedBytes: Int64 {
        sumEstimatedBytes(confirmedLocalCandidates.filter {
            selectedIDs.contains($0.record.localIdentifier)
        })
    }

    private var totalLocalBytes: Int64 {
        sumEstimatedBytes(confirmedLocalCandidates)
    }

    private func sumEstimatedBytes(_ values: [LargeMediaCandidate]) -> Int64 {
        values.reduce(into: Int64(0)) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.estimatedBytes)
            total = overflow ? Int64.max : sum
        }
    }

    var body: some View {
        content
            .navigationTitle("大媒体清理")
            .toolbar(.hidden, for: .tabBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .onAppear {
                tabBarState.isHidden = true
                reload()
            }
            .onDisappear { tabBarState.isHidden = false }
            .onChange(of: scenePhase, perform: handleScenePhaseChange)
            .onChange(of: environment.libraryRevision) { _ in handleLibraryRevisionChange() }
            .fullScreenCover(item: Binding(
                get: { viewerAssetID.map { SingleAssetViewerContext(id: $0) } },
                set: { viewerAssetID = $0?.id }
            )) { context in
                let record = recordForViewer(id: context.id)
                SinglePhotoViewer(
                    localIdentifier: context.id,
                    onDismiss: { viewerAssetID = nil },
                    mediaType: record?.mediaType ?? .image,
                    isLivePhoto: record?.isLivePhoto ?? false,
                    onLoadOutcome: { succeeded in
                        handlePreviewOutcome(id: context.id, succeeded: succeeded)
                    }
                )
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // 无安全建议时按钮置灰，仍明确提供“全选建议”入口。
            suggestionToggle
            summaryHeader
            statusBanner
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
    }

    @ViewBuilder
    private var statusBanner: some View {
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
            .padding(6)
        }
    }

    private func recordForViewer(id: String) -> AssetRecord? {
        candidates.first { candidate in
            candidate.record.localIdentifier == id
        }?.record
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        reload()
    }

    private func handleLibraryRevisionChange() {
        reload()
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
                    row(candidate, selectable: candidate.record.localAvailability == .available)
                }
            } header: {
                if !unknownCandidates.isEmpty {
                    Text("未知状态的项目不可勾选，也不计入可释放估算")
                }
            }

            if !unknownCandidates.isEmpty {
                Section {
                    if showUnknown {
                        ForEach(unknownCandidates, id: \.record.localIdentifier) { candidate in
                            row(candidate, selectable: false)
                        }
                    }
                } header: {
                    Button {
                        showUnknown.toggle()
                    } label: {
                        HStack {
                            Image(systemName: showUnknown ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text("状态未知 \(unknownCandidates.count) 项 · 不计入可释放估算")
                        }
                    }
                    .buttonStyle(.plain)
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
                availabilityLabel(candidate)
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
                .frame(width: 44, height: 44)
                .accessibilityLabel(selected ? "取消选择大媒体" : "选择大媒体")
                .accessibilityValue(selected ? "已选中" : "未选中")
            }
        }
        .contextMenu {
            if selectable {
                Button("保留，不再建议") { keepFromSuggestions(id) }
            }
        }
    }

    /// 三态可用性标签。未知**不得**显示成"iCloud 未下载"——两者含义不同：
    /// 前者是探测没结论，后者是确认原件只在云端。
    @ViewBuilder
    private func availabilityLabel(_ candidate: LargeMediaCandidate) -> some View {
        switch candidate.record.localAvailability {
        case .available:
            Text("本机可用")
                .font(.caption2)
                .foregroundStyle(.green)
        case .notDownloaded:
            Text("iCloud 未下载")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unknown:
            HStack(spacing: 4) {
                Text("状态未知")
                Button("重新探测") { reprobe(candidate.record.localIdentifier) }
                    .font(.caption2.weight(.semibold))
                    .disabled(isReprobing.contains(candidate.record.localIdentifier))
            }
            .font(.caption2)
            .foregroundStyle(.orange)
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
        // 只有确认本机可用的项目保留勾选——unknown 与 notDownloaded 都不可勾选。
        let validIDs = Set(candidates.filter { $0.record.localAvailability == .available }
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

    /// 预览结果回落。
    ///
    /// 语义关键：**缩略图/预览成功 ≠ 原件在本机**。PhotoKit 可能在只有
    /// 低分辨率代理或优化存储的情况下成功交付预览，因此这里只在
    /// "可本地预览"这一维度更新页面提示，不擅自把可用性提升为 `.available`。
    /// 要确认原件在本机，必须走 probeLocalAvailability 的资源级探测。
    private func handlePreviewOutcome(id: String, succeeded: Bool) {
        guard succeeded else { return }
        guard let candidate = candidates.first(where: { $0.record.localIdentifier == id }),
              candidate.record.localAvailability == .unknown else { return }
        // 未知状态：预览成功说明本机至少有可解码表示，提示用户可以做一次
        // 确定性的资源探测来把状态落实，而不是直接当作已确认。
        statusText = "这项可以本地预览，但尚未确认原件在本机；可点\"重新探测\"确认后再删除。"
    }

    /// 重新探测单项可用性。探测在服务层后台执行，不阻塞主线程也不触发下载；
    /// 成功后把新状态写回候选列表，未知状态因此有机会转成确定的可用/未下载。
    private func reprobe(_ id: String) {
        guard !isReprobing.contains(id) else { return }
        isReprobing.insert(id)
        statusText = "正在重新探测本机可用性…"
        environment.photoLibraryService.probeLocalAvailability(of: [id]) { mapping in
            isReprobing.remove(id)
            guard let availability = mapping[id] else {
                statusText = "这项资产已不存在，请刷新列表。"
                return
            }
            applyAvailability([id: availability])
            switch availability {
            case .available:
                statusText = "已确认原件在本机，可以勾选删除。"
            case .notDownloaded:
                statusText = "已确认原件仅在 iCloud，未下载到本机。"
            case .unknown:
                statusText = "仍无法确认本机状态，未计入可释放空间。"
            }
        }
    }

    /// 把探测结果写回候选列表并按新状态收敛勾选，避免已不可用的项目留在勾选集里。
    private func applyAvailability(_ mapping: [String: AssetLocalAvailability]) {
        candidates = candidates.map { candidate in
            guard let availability = mapping[candidate.record.localIdentifier] else {
                return candidate
            }
            return LargeMediaCandidate(
                record: candidate.record.withLocalAvailability(availability),
                estimatedBytes: candidate.estimatedBytes,
                isOnlyInGroup: candidate.isOnlyInGroup
            )
        }
        let selectable = Set(candidates
            .filter { $0.record.localAvailability == .available }
            .map(\.record.localIdentifier))
        selectedIDs.formIntersection(selectable)
        selectionSources = selectionSources.filter { selectable.contains($0.key) }
    }

    private func keepFromSuggestions(_ id: String) {
        guard environment.database.setDecision(
            assetId: id,
            verdict: .keep,
            reason: "user_override",
            decidedAt: Date()
        ) else {
            statusText = "保留操作未保存，请检查存储空间后重试。"
            return
        }
        undoKeepID = id
        selectedIDs.remove(id)
        selectionSources[id] = nil
        environment.engine.removeLargeMediaCandidates(assetIds: [id]) {
            DispatchQueue.main.async { reload() }
        }
        statusText = "已保留这项大媒体，之后不会自动建议删除。"
    }

    private func undoKeep() {
        guard let id = undoKeepID else { return }
        guard environment.database.removeDecision(assetId: id) else {
            statusText = "撤销保留未保存，请检查存储空间后重试。"
            return
        }
        undoKeepID = nil
        statusText = "已撤销保留；下一次扫描会重新评估这项大媒体。"
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
