// MARK: - ScreenshotInboxView
// 职责：截图任务箱列表页（P8）——类别 chips、时间筛选、待定分区、
//       四动作入口；动作完成即落 decisions（action:*）并标记"已处理"。
// 任务卡：T15。红线 5：低置信"待定"只展示不自动执行任何写动作。

import SwiftUI
import UIKit

struct ScreenshotInboxView: View {
    let environment: AppEnvironment

    @State private var rows: [PhotoLibraryDatabase.ScreenshotInboxRow] = []
    @State private var selectedCategory: String?
    @State private var selectedWindow: ScreenshotTimeWindow?
    @State private var toast: String?
    @State private var shareURL: ShareContext?
    @State private var busyAssetId: String?

    /// 时间窗过滤后的全部行（DB 已按 creation_date 降序）。
    private var windowedRows: [PhotoLibraryDatabase.ScreenshotInboxRow] {
        guard let selectedWindow else { return rows }
        let now = Date()
        return rows.filter {
            ScreenshotTimeWindow.bucket(of: $0.creationDate, now: now) == selectedWindow
        }
    }

    /// 待定分区（红线 5：只人工确认，不给主动作）。
    private var pendingRows: [PhotoLibraryDatabase.ScreenshotInboxRow] {
        windowedRows.filter { $0.isPending }
    }

    /// 可执行任务分区（未处理 + 非待定）。
    private var actionableRows: [PhotoLibraryDatabase.ScreenshotInboxRow] {
        windowedRows.filter { !$0.isPending && !$0.isProcessed }
    }

    /// 已处理分区（动作完成，进可清理队列的口径提示）。
    private var processedRows: [PhotoLibraryDatabase.ScreenshotInboxRow] {
        windowedRows.filter { $0.isProcessed }
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryChips
            windowMenu
            list
        }
        .navigationTitle("截图任务箱")
        .onAppear(perform: reload)
        .safeAreaInset(edge: .bottom) { toastBar }
        .sheet(item: $shareURL) { context in
            ActivityShareSheet(items: [context.url])
        }
    }

    // MARK: 子视图

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, label: "全部")
                ForEach(ScreenshotInboxFilter.categoryOrder, id: \.self) { category in
                    chip(category, label: ScreenshotInboxFilter.displayName(for: category))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ category: String?, label: String) -> some View {
        Button {
            selectedCategory = category
            reload()
        } label: {
            Text(label + badgeSuffix(category))
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selectedCategory == category ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    /// chips 角标：该类别待处理数（仅"全部"与各类别显示）。
    private func badgeSuffix(_ category: String?) -> String {
        let pending = rows.filter { row in
            !row.isPending && !row.isProcessed &&
            (category == nil || row.category == category)
        }.count
        return pending > 0 ? " \(pending)" : ""
    }

    private var windowMenu: some View {
        Picker("时间", selection: Binding(
            get: { selectedWindow },
            set: { selectedWindow = $0; reload() }
        )) {
            Text("全部时间").tag(ScreenshotTimeWindow?.none)
            ForEach(ScreenshotTimeWindow.allCases, id: \.self) { window in
                Text(window.rawValue).tag(ScreenshotTimeWindow?.some(window))
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var list: some View {
        List {
            section("待处理", rows: actionableRows, allowsAction: true)
            section("待人工确认", rows: pendingRows, allowsAction: false)
            if !processedRows.isEmpty {
                section("已处理", rows: processedRows, allowsAction: false)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if windowedRows.isEmpty {
                ContentUnavailableView(
                    "这里还很干净",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("扫描完成后，识别出任务的截图会出现在这里")
                )
            }
        }
    }

    @ViewBuilder
    private func section(
        _ title: String,
        rows: [PhotoLibraryDatabase.ScreenshotInboxRow],
        allowsAction: Bool
    ) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.assetId) { row in
                    rowView(row, allowsAction: allowsAction)
                }
            }
        }
    }

    private func rowView(
        _ row: PhotoLibraryDatabase.ScreenshotInboxRow,
        allowsAction: Bool
    ) -> some View {
        HStack(spacing: 12) {
            AssetThumbnailView(side: 52, localIdentifier: row.assetId)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ScreenshotInboxFilter.displayName(for: row.category))
                        .font(.subheadline.weight(.medium))
                    if row.source == "llm" {
                        Text("AI").font(.caption2).foregroundStyle(.secondary)
                    }
                    if row.isProcessed {
                        Text("已处理").font(.caption2).foregroundStyle(.green)
                    } else if row.isPending {
                        Text("待定").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if let summary = rowSummary(row), !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let date = row.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if allowsAction, !row.isProcessed, busyAssetId != row.assetId {
                actionButton(row)
            } else if busyAssetId == row.assetId {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("复制文本") {
                perform(.copyText, row: row)
            }
        }
    }

    /// 主动作按钮（按类别路由；无路由类别不显示按钮）。
    @ViewBuilder
    private func actionButton(_ row: PhotoLibraryDatabase.ScreenshotInboxRow) -> some View {
        if let action = ScreenshotActionRouter.primaryAction(
            category: row.category,
            confidence: row.confidence,
            suggestedAction: row.suggestedAction
        ) {
            Button(actionLabel(action)) {
                perform(action, row: row)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func actionLabel(_ action: ScreenshotTaskAction) -> String {
        switch action {
        case .markTemporary: return "标记临时"
        case .copyText: return "复制"
        case .createCalendarEvent: return "加日历"
        case .exportPDF: return "转 PDF"
        case .manualReview: return "查看"
        }
    }

    private var toastBar: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .transition(.move(edge: .bottom))
            }
        }
    }

    // MARK: 数据与动作

    private func reload() {
        rows = environment.database.screenshotInboxRows(category: selectedCategory)
    }

    /// 行摘要：提取字段优先，回退 OCR 首行。
    private func rowSummary(_ row: PhotoLibraryDatabase.ScreenshotInboxRow) -> String? {
        if let field = TaskActionExecutor.firstFieldValue(in: row.extractedFieldsJSON) {
            return field
        }
        return row.ocrText
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func perform(_ action: ScreenshotTaskAction, row: PhotoLibraryDatabase.ScreenshotInboxRow) {
        busyAssetId = row.assetId
        toast = nil
        Task {
            defer { busyAssetId = nil }
            do {
                let outcome = try await execute(action, row: row)
                record(action: action, assetId: row.assetId, outcome: outcome)
                toast = outcomeMessage(outcome)
                reload()
            } catch {
                // 错误态可见且不吞掉原状态（P9 验收）：不改分类、不标已处理。
                toast = error.localizedDescription
            }
        }
    }

    private func execute(
        _ action: ScreenshotTaskAction,
        row: PhotoLibraryDatabase.ScreenshotInboxRow
    ) async throws -> TaskActionOutcome {
        switch action {
        case .copyText:
            return try TaskActionExecutor.copyText(fieldsJSON: row.extractedFieldsJSON, ocrText: row.ocrText)
        case .markTemporary:
            return TaskActionExecutor.markTemporary()
        case .createCalendarEvent:
            return try await TaskActionExecutor.createCalendarEvent(
                ocrText: row.ocrText,
                writer: EventKitCalendarWriter()
            )
        case .exportPDF:
            guard let data = environment.imageData(for: row.assetId, maxDimension: AppConfig.pdfExportMaxDimension) else {
                throw TaskActionExecutor.ActionError.pdfComposeFailed
            }
            return try TaskActionExecutor.exportPDF(imageData: data)
        case .manualReview:
            throw TaskActionExecutor.ActionError.nothingToCopy
        }
    }

    /// 动作落库：统一走 decisions 的 action:* 口径（首页统计复用）。
    private func record(action: ScreenshotTaskAction, assetId: String, outcome: TaskActionOutcome) {
        switch outcome {
        case .markedTemporary:
            environment.database.setDecision(
                assetId: assetId,
                verdict: .todo,
                reason: TemporaryMarker.reasonWithExpiry(from: Date()),
                decidedAt: Date()
            )
        default:
            environment.database.markActionTaken(assetId: assetId, action: action.rawValue)
        }
    }

    private func outcomeMessage(_ outcome: TaskActionOutcome) -> String {
        switch outcome {
        case .copied(let text): return "已复制：\(text)"
        case .markedTemporary(let expiry):
            let days = Int(expiry.timeIntervalSinceNow / 86_400)
            return "已标记临时，约 \(max(days, 0)) 天后提醒清理"
        case .calendarEventCreated: return "已写入日历事件"
        case .pdfReady(let url): return "PDF 已生成，选择分享方式"
        }
    }
}

/// 分享面板上下文（Identifiable 以配 sheet(item:)）。
struct ShareContext: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
