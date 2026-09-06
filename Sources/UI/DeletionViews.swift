// MARK: - DeletionViews
// 职责：安全删除流的两个页面——待删清单（按相似组分节 + 组内多选 +
//       触发系统确认框）与最近删除教育页（30 天可恢复 / 永不静默清除）。
// 任务卡：T10。文案红线：不出现"立即彻底删除"类误导表述；
//        彻底删除永远是用户去系统相册做的动作。
// 审阅结构红线：候选必须按相似组呈现（P4/P5 的核心交互），
//        不许拍平成无差别列表让用户对着编号猜。

import SwiftUI
import Photos

/// 待删清单页：每个相似组一节，横排展示组内成员（Best Shot 星标），
/// 建议删除项可快速勾选，用户也可手动选择组内任意成员后统一进系统确认框。
struct DeletionReviewView: View {
    /// 候选组（已过 SafetyRules；preselectableIDs 即可勾选成员）。
    @ObservedObject var environment: AppEnvironment
    let deletionService: PhotoLibraryServiceProtocol
    let database: PhotoLibraryDatabase
    @EnvironmentObject private var tabBarState: RootTabBarState
    /// 删除完成回调（刷新清单/组视图）。
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var selectedIDs: Set<String> = []
    @State private var selectionSources: [String: DeletionSelectionSource] = [:]
    @State private var isDeleting = false
    @State private var statusText: String?
    @State private var viewerContext: ViewerContext?
    /// 删除回调异步返回时，页面也要立即从本地列表移除已消失成员，
    /// 避免继续显示已删除缩略图或把它们再次提交到系统确认框。
    @State private var visibleCandidates: [ScoredGroup]
    private let deletionCoordinator: DeletionCoordinator

    init(
        candidates: [ScoredGroup],
        environment: AppEnvironment,
        deletionService: PhotoLibraryServiceProtocol,
        database: PhotoLibraryDatabase,
        onDeleted: @escaping ([String]) -> Void = { _ in }
    ) {
        self.environment = environment
        self.deletionService = deletionService
        self.database = database
        self.deletionCoordinator = DeletionCoordinator(
            photoLibrary: deletionService,
            database: database
        )
        self.onDeleted = onDeleted
        _visibleCandidates = State(initialValue: candidates)
    }

    private var displayableGroups: [ScoredGroup] {
        visibleCandidates.filter { $0.members.count >= 2 }
    }

    private var totalPreselectableCount: Int {
        displayableGroups.reduce(0) { $0 + $1.preselectableIDs.count }
    }

    /// 所有组的全部可建议删除 id（跨组，用于全局一键全选/取消全选）。
    private var allPreselectableIDs: Set<String> {
        Set(displayableGroups.flatMap(\.preselectableIDs))
    }

    /// 全局建议项是否已全部选中——用于切换按钮文案。
    private var allSuggestedSelected: Bool {
        let target = allPreselectableIDs
        return !target.isEmpty && target.allSatisfy { selectedIDs.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            if displayableGroups.isEmpty {
                ContentUnavailableView(
                    "暂无待删候选",
                    systemImage: "checkmark.seal",
                    description: Text("扫描完成后，经安全规则过滤的相似组会出现在这里")
                )
            } else {
                groupedList
            }

            // 全局一键全选所有组的建议删除（跨组操作）。无安全建议时仍
            // 保留按钮并置灰，用户能明确看到当前页面支持该操作。
            suggestionToggle

            NavigationLink("为什么删除的照片还能找回 30 天？") {
                RecentlyDeletedEducationView()
            }
            .font(.footnote)
            .padding(.vertical, 8)
        }
        .navigationTitle("待删清单")
        .toolbar(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .onAppear {
            tabBarState.isHidden = true
            reloadFromEnvironment()
        }
        .onDisappear { tabBarState.isHidden = false }
        .onChange(of: environment.libraryRevision) { _ in
            reloadFromEnvironment()
        }
        .fullScreenCover(item: $viewerContext) { context in
            GroupPhotoViewer(
                group: context.group,
                startIndex: context.startIndex,
                selectedIDs: $selectedIDs,
                selectionSources: $selectionSources
            )
        }
    }

    private var suggestionToggle: some View {
        Button(allSuggestedSelected ? "取消全选" : "全选建议") {
            if allSuggestedSelected {
                selectedIDs.subtract(allPreselectableIDs)
                allPreselectableIDs.forEach { selectionSources[$0] = nil }
            } else {
                selectedIDs.formUnion(allPreselectableIDs)
                allPreselectableIDs.forEach { selectionSources[$0] = .suggestion }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .disabled(allPreselectableIDs.isEmpty)
    }

    private var groupedList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(displayableGroups, id: \.groupID) { group in
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(group.members.enumerated()), id: \.element.record.localIdentifier) { index, member in
                                    memberCard(member, group: group, index: index)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    } header: {
                        HStack {
                            Text("\(shortGroupLabel(group)) · 共 \(group.members.count) 张")
                            Spacer()
                            let allSelected = !group.preselectableIDs.isEmpty
                                && group.preselectableIDs.allSatisfy { selectedIDs.contains($0) }
                            Button(allSelected ? "取消全选" : "全选建议") {
                                if allSelected {
                                    selectedIDs.subtract(group.preselectableIDs)
                                    group.preselectableIDs.forEach { selectionSources[$0] = nil }
                                } else {
                                    selectedIDs.formUnion(group.preselectableIDs)
                                    group.preselectableIDs.forEach {
                                        selectionSources[$0] = .suggestion
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                confirmDeletion()
            } label: {
                Text(selectedIDs.isEmpty
                     ? "勾选要删除的照片（共 \(totalPreselectableCount) 张候选）"
                     : "进入系统确认框，删除 \(selectedIDs.count) 张")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty || isDeleting)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// 组内成员卡片：点缩略图本体开全屏原图；右下角小圆钮单独触控勾选。
    /// 所有成员（含 ★ 最佳）都可手动勾选——红线只约束"自动预选"，
    /// 用户亲手勾选并经系统确认框属于最终决定权；★ 默认不勾。
    private func memberCard(_ member: ScoredMember, group: ScoredGroup, index: Int) -> some View {
        let id = member.record.localIdentifier
        let suggested = group.preselectableIDs.contains(id)
        let selected = selectedIDs.contains(id)

        return VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                // 图片区：点缩略图本身 → 开全屏查看原图。
                AssetThumbnailView(side: 84, localIdentifier: id)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        viewerContext = ViewerContext(group: group, startIndex: index)
                    }

                // 选中态边框（纯视觉，不拦截触控）。
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.red : Color.clear, lineWidth: 2.5)
                    .allowsHitTesting(false)

                if member.isBestShot {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 右下角勾选圆钮：独立点击目标，不被 onTapGesture 吞掉。
                Button { toggleSelection(id) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? .red : .gray)
                        .shadow(radius: 2)
                }
                .buttonStyle(.borderless)
                .padding(4)
            }

            HStack(spacing: 4) {
                if member.isBestShot {
                    Text("★最佳").font(.caption2).foregroundStyle(.yellow)
                }
                if suggested {
                    Text("建议删").font(.caption2).foregroundStyle(.red)
                }
                Text(String(format: "%.2f", member.score))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func shortGroupLabel(_ group: ScoredGroup) -> String {
        let suffix = group.groupID.suffix(8)
        return "组 #\(suffix)"
    }

    private func confirmDeletion() {
        isDeleting = true
        statusText = "正在复核最新相册状态…"
        let selections = selectedIDs.sorted().map { id in
            DeletionSelection(assetID: id, source: selectionSources[id] ?? .user)
        }
        deletionCoordinator.execute(selections: selections, groups: visibleCandidates) { preflight, result in
            let approved = Set(result?.approvedIDs ?? [])
            let blockedText = preflight.blocked.map { "\($0.assetID)：\($0.reason.rawValue)" }.joined(separator: "、")
            if !approved.isEmpty {
                database.markDeleted(assetIds: Array(approved))
                selectedIDs.subtract(approved)
                approved.forEach { selectionSources[$0] = nil }
                removeDeletedFromVisible(approved)
                onDeleted(Array(approved))
            }
            isDeleting = false
            if preflight.safetyDataAvailable == false {
                statusText = "无法读取保留记录，未提交任何删除。"
            } else if let result, result.cancelled {
                statusText = "已记录此前批准的项目；系统确认被取消，后续批次未执行。"
            } else if let result, result.hasFailure {
                statusText = "已记录此前批准的项目；后续批次失败，未执行的项目可重试。"
            } else if !blockedText.isEmpty {
                statusText = "部分选择已撤销：\(blockedText)"
            } else if !approved.isEmpty {
                statusText = "已批准删除。照片将在系统\"最近删除\"保留约 30 天。"
            } else {
                statusText = "没有仍符合安全条件的选择。"
            }
        }
    }

    private func reloadFromEnvironment() {
        let latest = environment.engine.scoredGroups
        visibleCandidates = latest
        let visibleIDs = Set(visibleCandidates.flatMap { group in
            group.members.map { $0.record.localIdentifier }
        })
        selectedIDs.formIntersection(visibleIDs)
        selectionSources = selectionSources.filter { visibleIDs.contains($0.key) }
    }

    private func removeDeletedFromVisible(_ deleted: Set<String>) {
        let protectedIDs = database.assetIDs(withVerdict: .keep)
        visibleCandidates = visibleCandidates.compactMap { group in
            let remaining = group.members.filter { !deleted.contains($0.record.localIdentifier) }
            guard remaining.count >= 2 else { return nil }
            let rebuiltMembers = remaining.enumerated().map { index, member in
                ScoredMember(
                    record: member.record,
                    score: member.score,
                    isBestShot: index == 0
                )
            }
            let newBestID = rebuiltMembers.first?.record.localIdentifier
            let remainingIDs = Set(remaining.map { $0.record.localIdentifier })
            return ScoredGroup(
                groupID: group.groupID,
                reason: group.reason,
                members: rebuiltMembers,
                // UI 侧没有特征向量，删除后只能收窄原有建议，不能凭空
                // 生成新建议；同时把删除后新的 Best Shot 排除在预选外。
                preselectableIDs: group.preselectableIDs.filter {
                    remainingIDs.contains($0)
                        && $0 != newBestID
                        && !protectedIDs.contains($0)
                }
            )
        }
        let visibleIDs = Set(visibleCandidates.flatMap { group in
            group.members.map { $0.record.localIdentifier }
        })
        selectedIDs.formIntersection(visibleIDs)
        selectionSources = selectionSources.filter { visibleIDs.contains($0.key) }
    }
}

/// 全屏原图查看器：左右滑动浏览组内成员，滑动到哪张就能直接勾选哪张。
struct ViewerContext: Identifiable {
    let id = UUID()
    let group: ScoredGroup
    let startIndex: Int
}

struct GroupPhotoViewer: View {
    let group: ScoredGroup
    @State private var currentIndex: Int
    @Binding var selectedIDs: Set<String>
    @Binding var selectionSources: [String: DeletionSelectionSource]
    @Environment(\.dismiss) private var dismiss

    init(
        group: ScoredGroup,
        startIndex: Int,
        selectedIDs: Binding<Set<String>>,
        selectionSources: Binding<[String: DeletionSelectionSource]>
    ) {
        self.group = group
        _currentIndex = State(initialValue: startIndex)
        _selectedIDs = selectedIDs
        _selectionSources = selectionSources
    }

    private var currentMember: ScoredMember? {
        group.members.indices.contains(currentIndex) ? group.members[currentIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("第 \(min(currentIndex + 1, group.members.count)) / \(group.members.count) 张")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            TabView(selection: $currentIndex) {
                ForEach(Array(group.members.enumerated()), id: \.element.record.localIdentifier) { _, member in
                    FullPhotoView(localIdentifier: member.record.localIdentifier)
                        .tag(group.members.firstIndex { $0.record.localIdentifier == member.record.localIdentifier } ?? 0)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            if let member = currentMember {
                bottomBar(member)
            }
        }
        .background(Color(.systemBackground))
    }

    private func bottomBar(_ member: ScoredMember) -> some View {
        let id = member.record.localIdentifier
        let selected = selectedIDs.contains(id)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if member.isBestShot {
                        Text("★ 最佳").font(.footnote).foregroundStyle(.yellow)
                    }
                    if group.preselectableIDs.contains(id) {
                        Text("建议删").font(.footnote).foregroundStyle(.red)
                    }
                    Text(String(format: "保留分 %.2f", member.score))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(id).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button {
                if selected {
                    selectedIDs.remove(id)
                    selectionSources[id] = nil
                } else {
                    selectedIDs.insert(id)
                    selectionSources[id] = .user
                }
            } label: {
                Text(selected ? "✓ 已选中（点此取消）" : "选中此张")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(selected ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15),
                                in: Capsule())
                    .foregroundStyle(selected ? .red : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

/// 单页大图：按屏幕级尺寸从 PhotoKit 拉取（只读，iCloud 未下载不触发下载）。
struct FullPhotoView: View {
    let localIdentifier: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(.systemGray6)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
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
                if let delivered {
                    self.image = delivered
                } else {
                    self.failed = true
                }
            }
        }
    }
}

/// 资产缩略图：按 localIdentifier 从 PhotoKit 拉小图（只读，不触发 iCloud 下载）。
struct AssetThumbnailView: View {
    var side: CGFloat = 56
    let localIdentifier: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                ZStack {
                    Rectangle().fill(Color(.systemGray5))
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Rectangle().fill(Color(.systemGray5))
                    ProgressView()
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false   // iCloud 未下载资产显示占位，不触发下载
            options.isSynchronous = true
            // 2x 显示尺寸；isSynchronous 下 handler 同步回调。
            var delivered: UIImage?
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side * 2, height: side * 2),
                contentMode: .aspectFill,
                options: options
            ) { img, _ in delivered = img }
            DispatchQueue.main.async {
                if let delivered {
                    self.image = delivered
                } else {
                    self.failed = true
                }
            }
        }
    }
}

/// 最近删除教育页（T10 目标第三条）。
struct RecentlyDeletedEducationView: View {
    @EnvironmentObject private var tabBarState: RootTabBarState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                educationBlock(
                    title: "删除的照片去哪了",
                    body: "你在系统确认框中批准的删除，会先进入 iOS 系统的\"最近删除\"相簿，保留约 30 天，随时可以自己恢复。"
                )
                educationBlock(
                    title: "本 App 的承诺",
                    body: "本 App 永不做静默删除：每一次删除都必须经过系统确认框，由你亲自逐次批准。App 内没有任何绕过确认框的路径。"
                )
                educationBlock(
                    title: "如何彻底删除",
                    body: "打开系统\"照片\"App → 相簿 → 最近删除 → 选择 → 删除。彻底删除只能由你在系统相册中完成，本 App 不代劳。"
                )
                educationBlock(
                    title: "哪些照片永远不会被推荐删除",
                    body: "收藏过的、编辑过的、组内没有相似替代的照片。这些规则写死在代码里，任何功能都不能改变。"
                )
            }
            .padding()
        }
        .navigationTitle("关于最近删除")
        .toolbar(.hidden, for: .tabBar)
        .onAppear { tabBarState.isHidden = true }
        .onDisappear { tabBarState.isHidden = false }
    }

    private func educationBlock(title: String, body text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
