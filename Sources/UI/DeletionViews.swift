// MARK: - DeletionViews
// 职责：安全删除流的两个页面——待删清单（网格多选 + 触发系统确认框）
//       与最近删除教育页（30 天可恢复 / 本 App 永不静默清除）。
// 任务卡：T10。文案红线：不出现"立即彻底删除"类误导表述；
//        彻底删除永远是用户去系统相册做的动作。

import SwiftUI
import Photos

/// 待删清单页：展示评分+SafetyRules 过滤后的预删除候选，用户多选后
/// 触发 requestDelete——真正的删除发生在系统确认框里。
struct DeletionReviewView: View {
    /// 候选条目（已过 SafetyRules；id 即 localIdentifier）。
    let candidates: [ScoredGroup]
    let deletionService: PhotoLibraryServiceProtocol
    let database: PhotoLibraryDatabase
    /// 删除完成回调（刷新清单/组视图）。
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var selectedIDs: Set<String> = []
    @State private var isDeleting = false
    @State private var statusText: String?

    private var allCandidateIDs: [String] {
        DeletionFlow.pendingDeletionIDs(from: candidates)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            if allCandidateIDs.isEmpty {
                ContentUnavailableView(
                    "暂无待删候选",
                    systemImage: "checkmark.seal",
                    description: Text("扫描完成后，经安全规则过滤的候选会出现在这里")
                )
            } else {
                candidateGrid
            }

            NavigationLink("为什么删除的照片还能找回 30 天？") {
                RecentlyDeletedEducationView()
            }
            .font(.footnote)
            .padding(.vertical, 8)
        }
        .navigationTitle("待删清单")
    }

    private var candidateGrid: some View {
        VStack(spacing: 12) {
            List(allCandidateIDs, id: \.self) { id in
                Button {
                    if selectedIDs.contains(id) {
                        selectedIDs.remove(id)
                    } else {
                        selectedIDs.insert(id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIDs.contains(id) ? Color.accentColor : .secondary)
                        AssetThumbnailView(localIdentifier: id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("待确认候选")
                                .font(.subheadline)
                            Text(id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .foregroundStyle(.primary)
            }
            .listStyle(.plain)

            Button {
                confirmDeletion()
            } label: {
                // 文案指向系统确认框流程，绝不暗示本 App 直接彻底删除。
                Text(selectedIDs.isEmpty ? "选择要删除的照片" : "进入系统确认框，删除 \(selectedIDs.count) 张")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty || isDeleting)
            .padding(.horizontal)
        }
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
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            // 2x of 56pt 显示尺寸。
            let thumbnail = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 112, height: 112),
                contentMode: .aspectFill,
                options: options
            ) { delivered, _ in delivered }
            DispatchQueue.main.async { self.image = thumbnail }
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
                    body: "你在系统确认框中批准的删除，会先进入 iOS 系统的\"最近删除\"相册，保留约 30 天，随时可以自己恢复。"
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
