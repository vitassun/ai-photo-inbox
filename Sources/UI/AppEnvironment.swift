// MARK: - AppEnvironment
// 职责：生产依赖装配（首个真实组装点）——数据库/键值存储/PhotoKit 服务/
//       扫描引擎（全注入）/通知调度。惰性单例，App 全生命周期持有。
// 任务卡：T14。

import Foundation
import Combine
import UIKit
import ImageIO

@MainActor
final class AppEnvironment: ObservableObject, PhotoLibraryChangeObserving {

    static let shared = AppEnvironment()

    let database: PhotoLibraryDatabase
    let store: KeyValueStore
    let photoLibraryService: SystemPhotoLibraryService
    private let imageProvider = PhotoKitImageDataProvider()
    private let changeMonitor: PhotoLibraryChangeMonitor
    let engine: ScanningEngine
    /// PhotoKit 增量事件的 UI 失效标记；候选快照本身由引擎锁保护，
    /// 这里仅用版本号通知 SwiftUI 重新读取镜像。
    @Published private(set) var libraryRevision = 0
    /// LLM 兜底客户端（T18 接线）：CloudConsent 是云端同意门闩——
    /// 未同意时零出网（本地规则路径），同意后才放行远端请求。
    let llmClient: LLMClientProtocol
    /// 磁盘库创建失败时仍保留可运行的内存库，但必须把降级状态暴露给 UI，
    /// 不能让用户误以为扫描/保留结果已经持久化。
    @Published private(set) var persistenceWarning: String? = nil

    init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let dbPath = docs.appendingPathComponent("inbox.sqlite").path

        if let diskDatabase = try? PhotoLibraryDatabase(path: dbPath) {
            database = diskDatabase
            persistenceWarning = nil
        } else {
            do {
                database = try PhotoLibraryDatabase.inMemory()
                persistenceWarning = "本地数据库不可用，本次结果只保存在内存中；请检查存储空间后重启 App。"
            } catch {
                fatalError("无法创建本地数据库：\(error)")
            }
        }
        store = GRDBKeyValueStore(database: database)
        photoLibraryService = SystemPhotoLibraryService()
        changeMonitor = PhotoLibraryChangeMonitor()
        engine = ScanningEngine(
            photoLibrary: photoLibraryService,
            database: database,
            store: store,
            imageDataLoader: { [imageProvider] id in
                imageProvider.imageData(for: id, maxDimension: AppConfig.thumbnailMaxDimension)
            },
            hashComputer: { PerceptualHash.hash(fromEncodedImageData: $0) },
            embeddingComputer: { data in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return try? VisionAnalysisService.extractVectorFromCGImage(image)
            },
            featureAnalyzer: { data in
                guard case .success(let result) = VisionAnalysisService.analyzeSync(imageData: data) else {
                    return nil
                }
                return result
            },
            exifReader: { EXIFExtractor.exif(fromEncodedImageData: $0) },
            assetExifReader: { [imageProvider] id in
                guard let data = imageProvider.originalImageData(for: id) else { return nil }
                return EXIFExtractor.exif(fromEncodedImageData: data)
            },
            exposureProbe: { data in
                // T16 曝光直方图探测：缩略图重采样 128px 后算过曝/欠曝占比。
                guard let gray = VisionAnalysisService.grayPixelsSync(imageData: data, side: 128) else {
                    return nil
                }
                let over = ImageQualityDSP.overExposedRatio(
                    grayPixels: gray.pixels, width: gray.width, height: gray.height
                ) ?? 0
                let under = ImageQualityDSP.underExposedRatio(
                    grayPixels: gray.pixels, width: gray.width, height: gray.height
                ) ?? 0
                return (over, under)
            },
            // 与 tech-spec §5 对齐：有足够用户裁决历史后不再翻倍收藏加成。
            hasUserData: database.decisionCount() >= 50
        )

        let remote = RemoteLLMClient(
            baseURL: AppConfig.llmBaseURL,
            tokenProvider: { LLMTokenStore.read() }
        )
        llmClient = ConsentGatedLLMClient(store: store, remote: remote)

        engine.setResultsChangedHandler { [weak self] in
            guard let self else { return }
            self.libraryRevision &+= 1
        }
        // 引擎可能在初始化期间已经开始异步恢复 done 快照；补一次主线程
        // 刷新，避免恢复通知早于 handler 绑定而丢失。
        DispatchQueue.main.async { [weak self] in
            self?.libraryRevision &+= 1
        }
        changeMonitor.delegate = self
    }

    /// 摘要（打开即算：全部来自本地库计数，不触发扫描——P2 验收口径）。
    func todaySummary(now: Date = Date()) -> DailyInboxSummary {
        let calendar = Calendar.current
        let dayStart = DailySummaryAggregator.dayStart(for: now, calendar: calendar)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        return DailyInboxSummary(
            dayStart: dayStart,
            newAssetCount: database.countAssets(createdAtOrAfter: dayStart, before: dayEnd),
            // 待确认数只来自当前有效建议集合。恢复尚未完成时显示 0，
            // 页面同时由扫描状态提示“恢复中”，不再拿旧裁决数量冒充当前结果。
            pendingDeletionCount: engine.state == .done
                ? engine.pendingDeletionIDs.count
                : 0,
            actionCount: database.countActions(atOrAfter: dayStart, before: dayEnd)
        )
    }

    /// PhotoKit 外部变更只更新本地索引并清理已删除视图；下一次扫描会重建受影响的候选组。
    /// 回调由 PhotoLibraryChangeMonitor 保证在主线程投递。
    func photoLibraryDidChange(_ event: PhotoLibraryChangeEvent) {
        libraryRevision &+= 1
        if !event.removedIdentifiers.isEmpty {
            database.removeAssetsFromLibrary(assetIds: event.removedIdentifiers)
            engine.purgeDeletedFromViews(assetIds: event.removedIdentifiers)
        }

        let changedIDs = Array(Set(event.insertedIdentifiers + event.updatedIdentifiers)).sorted()
        let fetchedAt = Date()
        let changedRecords = changedIDs.isEmpty
            ? []
            : photoLibraryService.fetchAssets(matching: changedIDs)
        if !database.upsert(assets: changedRecords, fetchedAt: fetchedAt) {
            persistenceWarning = "相册变更未能保存到本地数据库；请检查存储空间后重试。"
        }
        engine.refreshAfterLibraryChange(
            records: changedRecords,
            removedIDs: event.removedIdentifiers
        )
    }

    /// 只在权限已确定后建立 diff 基准；避免在首次授权前用空 fetch 结果注册，
    /// 导致授权完成后的首批资产永远不产生 inserted 事件。
    func startChangeMonitoringIfAuthorized() {
        guard photoLibraryService.authorizationStatus == .authorized
            || photoLibraryService.authorizationStatus == .limited else { return }
        changeMonitor.start()
    }

    // MARK: T15/T16 页面入口

    /// 低质量候选快照（引擎镜像读取）。
    func lowQualitySnapshot() -> [LowQualityCandidate] {
        engine.lowQualityCandidates
    }

    /// 大媒体候选快照（引擎镜像读取）。
    func largeMediaSnapshot() -> [LargeMediaCandidate] {
        engine.largeMediaCandidates
    }

    /// 原图/大图字节读取（PDF 导出等动作用）。maxDimension 控制采样上限。
    func imageData(for assetId: String, maxDimension: Int) -> Data? {
        imageProvider.imageData(for: assetId, maxDimension: maxDimension)
    }
}
