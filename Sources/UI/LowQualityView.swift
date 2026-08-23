// MARK: - LowQualityView
// 职责：低质量批量页（P6）——模糊/过曝/欠曝三分区网格、夜景豁免角标折叠区、
//       长按移出（user_override 反馈）、批量删除走系统确认框。
// 任务卡：T16。红线 6：豁免项永不进预选集合；删除必经系统确认框。

import SwiftUI

struct LowQualityView: View {
    let environment: AppEnvironment
    /// 删除完成回调（首页刷新摘要）。
    var onDeleted: ([String]) -> Void = { _ in }

    @State private var candidates: [LowQualityCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isDeleting = false
    @State private var statusText: String?
    @State private var showExempted = false

    private var exempted: [LowQualityCandidate] {
        candidates.filter(\.isNightExempt)
    }

    private var actionable: [LowQualityCandidate] {
        candidates.filter { !$0.isNightExempt }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
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
        .onAppear(perform: reload)
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
            Section("\(title) · \(rows.count) 张") {
                grid(rows, selectable: true)
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
            AssetThumbnailView(side: 84, localIdentifier: id)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.red : Color.clear, lineWidth: 2.5)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selectable {
                        Button {
                            toggleSelection(id)
                        } label: {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, selected ? .red : .gray)
                                .shadow(radius: 2)
                        }
                        .padding(4)
                    } else {
                        Image(systemName: "moon.stars.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("不是低质量，移出候选") {
                        moveOut(id)
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
        candidates = environment.engine.lowQualityCandidates
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
        environment.engine.removeLowQualityCandidates(assetIds: [id])
        selectedIDs.remove(id)
        reload()
    }

    private func confirmDeletion() {
        let ids = Array(selectedIDs)
        isDeleting = true
        statusText = "等待你在系统确认框中批准…"
        environment.photoLibraryService.requestDelete(of: ids) { success, error in
            isDeleting = false
            if success {
                environment.database.markDeleted(assetIds: ids)
                environment.engine.removeLowQualityCandidates(assetIds: ids)
                selectedIDs.removeAll()
                onDeleted(ids)
                statusText = "已批准删除。照片将在系统\"最近删除\"保留约 30 天。"
            } else {
                statusText = "未执行删除\(error.map { "：\($0.localizedDescription)" } ?? "。")可重试。"
            }
            reload()
        }
    }
}
