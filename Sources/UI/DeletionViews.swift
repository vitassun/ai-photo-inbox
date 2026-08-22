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

            NavigationLink("为什么删除的照片还能找回 30 天？") {
                RecentlyDeletedEducationView()
            }
            .font(.footnote)
            .padding(.vertical, 8)
        }
        .navigationTitle("待删清单")
    }

    private var groupedList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(displayableGroups, id: \.groupID) { group in
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(group.members, id: \.record.localIdentifier) { member in
                                    memberCard(member, group: group)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    } header: {
                        HStack {
                            Text("\(shortGroupLabel(group)) · 共 \(group.members.count) 张")
                            Spacer()
                            Button("全选本组") {
                                selectedIDs.formUnion(group.preselectableIDs)
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

    /// 组内成员卡片：缩略图 + 勾选态；Best Shot 星标且永不可选（红线）。
    private func memberCard(_ member: ScoredMember, group: ScoredGroup) -> some View {
        let id = member.record.localIdentifier
        let selectable = group.preselectableIDs.contains(id)
        let selected = selectedIDs.contains(id)

        return Button {
            if selectable {
                if selected {
                    selectedIDs.remove(id)
                } else {
                    selectedIDs.insert(id)
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    AssetThumbnailView(side: 84, localIdentifier: id)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected ? Color.red : Color.clear, lineWidth: 2.5)
                        )
                        .opacity(selectable || selected ? 1 : 0.45)

                    if member.isBestShot {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .transition(.scale)
                    }
                }
                Text(member.isBestShot ? "★ 最佳" : String(format: "分 %.2f", member.score))
                    .font(.caption2)
                    .foregroundStyle(selectable ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
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
