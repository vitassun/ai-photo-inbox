// MARK: - DeletionViews
// 职责：安全删除流的两个页面——待删清单（按相似组分节 + 组内多选 +
//       触发系统确认框）与最近删除教育页（30 天可恢复 / 永不静默清除）。
// 任务卡：T10。文案红线：不出现"立即彻底删除"类误导表述；
//        彻底删除永远是用户去系统相册做的动作。
// 审阅结构红线：候选必须按相似组呈现（P4/P5 的核心交互），
//        不许拍平成无差别列表让用户对着编号猜。

import SwiftUI
import Photos

/// 待删清单页：每个相似组一节，横排展示组内成员（Best Shot 星标、
/// 不可选），仅 SafetyRules 放行的成员可勾选，多组累计后统一进系统确认框。
struct DeletionReviewView: View {
    /// 候选组（已过 SafetyRules；preselectableIDs 即可勾选成员）。
    let candidates: [ScoredGroup]
    let deletionService: PhotoLibraryServiceProtocol
    let database: PhotoLibraryDatabase
    /// 删除完成回调（刷新清单/组视图）。
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var selectedIDs: Set<String> = []
    @State private var isDeleting = false
    @State private var statusText: String?
    @State private var viewerContext: ViewerContext?

    private var displayableGroups: [ScoredGroup] {
        candidates.filter { !$0.preselectableIDs.isEmpty }
    }

    private var totalPreselectableCount: Int {
        displayableGroups.reduce(0) { $0 + $1.preselectableIDs.count }
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

            // 全局一键全选所有组的建议删除（跨组操作）。
            if !displayableGroups.isEmpty && totalPreselectableCount > 0 {
                Button("全选所有建议删除（\(totalPreselectableCount) 张）") {
                    for group in displayableGroups {
                        selectedIDs.formUnion(group.preselectableIDs)
                    }
                }
                .font(.footnote)
                .padding(.bottom, 4)
            }

            NavigationLink("为什么删除的照片还能找回 30 天？") {
                RecentlyDeletedEducationView()
            }
            .font(.footnote)
            .padding(.vertical, 8)
        }
        .navigationTitle("待删清单")
        .fullScreenCover(item: $viewerContext) { context in
            GroupPhotoViewer(
                group: context.group,
                startIndex: context.startIndex,
                selectedIDs: $selectedIDs
            )
        }
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
                            Button("全选建议") {
                                selectedIDs.formUnion(group.preselectableIDs)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            // 全选所有建议删除按钮
            Button {
                selectAllPreselectable()
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("全选所有建议删除（\(totalPreselectableCount) 张）")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding(.horizontal)
            .padding(.top, 4)

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
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 全选所有组的建议删除项
    private func selectAllPreselectable() {
        for group in displayableGroups {
            selectedIDs.formUnion(group.preselectableIDs)
        }
    }

    private func shortGroupLabel(_ group: ScoredGroup) -> String {
        let suffix = group.groupID.suffix(8)
        return "组 #\(suffix)"
    }

    private func confirmDeletion() {
        let ids = Array(selectedIDs)
        isDeleting = true
        statusText = "等待你在系统确认框中批准…"
        deletionService.requestDelete(of: ids) { success, error in
            isDeleting = false
            if success {
                database.markDeleted(assetIds: ids)
                selectedIDs.removeAll()
                onDeleted(ids)
                statusText = "已批准删除。照片将在系统\"最近删除\"保留约 30 天。"
            } else {
                statusText = "未执行删除\(error.map { "：\($0.localizedDescription)" } ?? "。")可重试。"
            }
        }
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
    @Environment(\.dismiss) private var dismiss

    init(group: ScoredGroup, startIndex: Int, selectedIDs: Binding<Set<String>>) {
        self.group = group
        _currentIndex = State(initialValue: startIndex)
        _selectedIDs = selectedIDs
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
                } else {
                    selectedIDs.insert(id)
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
            DispatchQueue.main.async { self.image = delivered }
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
            DispatchQueue.main.async { self.image = delivered }
        }
    }
}

/// 最近删除教育页（T10 目标第三条）。
struct RecentlyDeletedEducationView: View {
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
    }

    private func educationBlock(title: String, body text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
