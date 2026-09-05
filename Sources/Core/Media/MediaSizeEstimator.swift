// MARK: - MediaSizeEstimator
// 职责：文件体积估算模型。PHAsset 无公开大小 API，KVC 取 fileSize 属灰色
//       地带已被否决（.research/q4-filesize.json 结论）——只能按像素/时长估算。
// 任务卡：T07。全部系数集中在 AppConfig（含出处与误差预期），本文件零魔法数。
//
// 误差预期：照片 ±30%（真机抽样校准入口见 T07 验收）；视频码率档位 ±40%。

import Foundation

enum MediaSizeEstimator {

    /// 视频码率档位，按最长边分辨率分档（系数见 AppConfig）。
    private static func videoBitrate(longestSide: Int) -> Int64 {
        switch longestSide {
        case 3840...: return AppConfig.videoBitrateBitsPerSecond4K
        case 1920..<3840: return AppConfig.videoBitrateBitsPerSecond1080p
        case 1280..<1920: return AppConfig.videoBitrateBitsPerSecond720p
        default: return AppConfig.videoBitrateBitsPerSecondFallback
        }
    }

    static func estimatedBytes(for record: AssetRecord) -> Int64? {
        switch record.mediaType {
        case .image:
            guard record.pixelWidth > 0, record.pixelHeight > 0 else { return nil }
            let pixels = Double(record.pixelWidth) * Double(record.pixelHeight)
            let multiplier: Double = record.isLivePhoto ? AppConfig.livePhotoSizeMultiplier : 1.0
            return safeInt64(pixels * AppConfig.photoEstimatedBytesPerPixel * multiplier)
        case .video:
            let longestSide = max(record.pixelWidth, record.pixelHeight)
            guard record.duration.isFinite else { return nil }
            let duration = min(max(record.duration, 0), AppConfig.videoDurationCapSeconds)
            return safeInt64(duration * Double(videoBitrate(longestSide: longestSide)) / 8)
        case .audio, .unknown:
            return nil
        }
    }

    /// 人可读的"约"字节数（PRD 红线：空间数字永远带"约"；本函数只出数值，
    /// "约"字由 UI 层拼接）。GB 向上取整到一位小数由 UI 决定，这里返回原始字节。
    static func displayBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "约未知" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }

    /// Double → Int64 的安全边界转换。异常元数据不应让扫描线程因溢出崩溃。
    private static func safeInt64(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0 else { return nil }
        if value >= Double(Int64.max) { return Int64.max }
        return Int64(value)
    }
}
