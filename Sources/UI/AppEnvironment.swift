// MARK: - AppEnvironment
// 职责：生产依赖装配（首个真实组装点）——数据库/键值存储/PhotoKit 服务/
//       扫描引擎（全注入）/通知调度。惰性单例，App 全生命周期持有。
// 任务卡：T14。

import Foundation
import UIKit
import ImageIO

@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment()

    let database: PhotoLibraryDatabase
    let store: KeyValueStore
    let photoLibraryService: SystemPhotoLibraryService
    private let imageProvider = PhotoKitImageDataProvider()
    let engine: ScanningEngine

    init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let dbPath = docs.appendingPathComponent("inbox.sqlite").path

        database = (try? PhotoLibraryDatabase(path: dbPath)) ?? (try! PhotoLibraryDatabase.inMemory())
        store = GRDBKeyValueStore(database: database)
        photoLibraryService = SystemPhotoLibraryService()
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
            screenshotOCR: { VisionAnalysisService.readTextSync(imageData: $0) },
            hasUserData: false   // V1 冷启动；用户反馈历史属后续迭代
        )
    }

    /// 摘要（打开即算：全部来自本地库计数，不触发扫描——P2 验收口径）。
    func todaySummary(now: Date = Date()) -> DailyInboxSummary {
        let calendar = Calendar.current
        let dayStart = DailySummaryAggregator.dayStart(for: now, calendar: calendar)
        return DailyInboxSummary(
            dayStart: dayStart,
            newAssetCount: database.countAssets(createdAtOrAfter: dayStart),
            pendingDeletionCount: database.countDeleteVerdicts(),
            actionCount: database.countActions(atOrAfter: dayStart)
        )
    }
}
