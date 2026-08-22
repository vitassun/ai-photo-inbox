// MARK: - LivePhotoPairing
// 职责：Live Photo 配对的纯函数分类——把"资产 → 组件集合"映射成
//      完整成对 / 孤儿组件三类，供删除流按原子单位处理（PRD 红线：不许拆散）。
// 任务卡：T07。组件清单由 Infrastructure 层从 PHAssetResource 提取后透传。

import Foundation

enum LivePhotoPairing {

    enum ComponentType: String, Equatable {
        case photo
        case pairedVideo
    }

    struct Classification: Equatable {
        /// 完整成对的资产 id（删除时整体作为一个确认单位）。
        var completePairs: [String]
        /// 只有视频组件、缺照片的孤儿资产（兜底归类为普通视频处理）。
        var orphanVideos: [String]
        /// 只有照片组件、缺配对视频的孤儿资产（兜底归类为普通照片处理）。
        var orphanPhotos: [String]
    }

    /// 按"同时含 photo + pairedVideo 两类组件"判定完整性。
    /// 既无 photo 也无 video 组件的资产视为非 Live Photo 输入，忽略。
    static func classify(componentsByAsset: [String: Set<ComponentType>]) -> Classification {
        var result = Classification(completePairs: [], orphanVideos: [], orphanPhotos: [])
        for (assetId, components) in componentsByAsset {
            let hasPhoto = components.contains(.photo)
            let hasVideo = components.contains(.pairedVideo)
            if hasPhoto && hasVideo {
                result.completePairs.append(assetId)
            } else if hasVideo {
                result.orphanVideos.append(assetId)
            } else if hasPhoto {
                result.orphanPhotos.append(assetId)
            }
        }
        return Classification(
            completePairs: result.completePairs.sorted(),
            orphanVideos: result.orphanVideos.sorted(),
            orphanPhotos: result.orphanPhotos.sorted()
        )
    }
}
