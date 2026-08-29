// MARK: - LargeMediaView
// 职责：大媒体清理页（P7）——估算体积降序列表、"约 xx"可释放汇总、
//       iCloud 未下载折叠分组、Live Photo 明示配对删除；批量删除走系统确认框。
// 任务卡：T17。红线 3：空间数字永远带"约"；未下载资产不计入可释放汇总。

import SwiftUI

struct LargeMediaView: View {
    let environment: AppEnvironment
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var candidates: [LargeMediaCandidate] = []
    @State private var selectedIDs: Set<String> = []
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

    /// 勾选集的可释放估算（仅本机资产可勾选）。
    private var selectedBytes: Int64 {
        localCandidates
            .filter { selectedIDs.contains($0.record.localIdentifier) }
            .reduce(0) { $0 + $1.estimatedBytes }
    }

    private var totalLocalBytes: Int64 {
        localCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .onAppear(perform: reload)
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
            let minutes = Int(record.duration / 60)
            return record.duration >= 60 ? "视频 · \(minutes) 分钟" : "视频 · \(Int(record.duration)) 秒"
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
        selectedIDs.formUnion(localCandidates.map(\.record.localIdentifier))
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func confirmDeletion() {
        let ids = Array(selectedIDs)
        isDeleting = true
        statusText = "等待你在系统确认框中批准…"
        environment.photoLibraryService.requestDelete(of: ids) { success, error in
            isDeleting = false
            if success {
                environment.database.markDeleted(assetIds: ids)
                environment.engine.purgeDeletedFromViews(assetIds: ids)
                selectedIDs.removeAll()
                onDeleted(ids)
                statusText = "已批准删除。项目将在系统\"最近删除\"保留约 30 天。"
            } else {
                statusText = "未执行删除\(error.map { "：\($0.localizedDescription)" } ?? "。")可重试。"
            }
            reload()
        }
    }
}
