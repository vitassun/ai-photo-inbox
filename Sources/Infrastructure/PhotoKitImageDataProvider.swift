// MARK: - PhotoKitImageDataProvider
// 职责：hashing 阶段的缩略图像素来源——经 PHImageManager 拉缩略图并
//      重编码为 JPEG 字节（特征计算的统一输入格式）。
// 任务卡：T04。只读元数据之外的缩略图层；绝不加载原图全尺寸字节。

import Foundation
import Photos
import UIKit

/// 扫描引擎的图像数据注入点（CI 测试用假实现替换）。
protocol ScanImageDataProvider {
    /// 返回资产缩略图的 JPEG 字节；失败返回 nil（该资产跳过哈希，走 T05 路线）。
    func imageData(for localIdentifier: String, maxDimension: Int) -> Data?
}

final class PhotoKitImageDataProvider: ScanImageDataProvider {

    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    func imageData(for localIdentifier: String, maxDimension: Int) -> Data? {
        guard !localIdentifier.isEmpty, maxDimension > 0 else { return nil }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false   // iCloud 未下载资产不触发下载（红线）
        options.isSynchronous = true
        // isSynchronous + 主线程外调用：回调在本线程返回。
        var thumbnail: UIImage?
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: maxDimension, height: maxDimension),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            thumbnail = image
        }
        guard let thumbnail, let data = thumbnail.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        return data
    }

    /// 读取资产原始编码数据，仅用于需要保留原始 EXIF 的判定（例如夜间长曝光豁免）。
    /// 与缩略图路径分开，避免 JPEG 重编码把原始曝光时间等元数据抹掉。
    func originalImageData(for localIdentifier: String) -> Data? {
        guard !localIdentifier.isEmpty else { return nil }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.version = .original
        // EXIF 白名单依赖原始编码数据；fastFormat 可能返回已重编码的代理图。
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true

        var originalData: Data?
        imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            originalData = data
        }
        return originalData
    }
}
