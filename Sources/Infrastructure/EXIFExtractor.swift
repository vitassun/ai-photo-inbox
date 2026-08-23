// MARK: - EXIFExtractor
// 职责：从编码图像字节解出 EXIF 字典（T16 夜间白名单的输入）。
// 任务卡：T16。纯 ImageIO 本地解析，不出网。

import Foundation
import ImageIO

enum EXIFExtractor {

    /// 首帧 "{Exif}" 子字典（键如 ExposureTime / ISOSpeedRatings / SceneCaptureType，
    /// 与 NightWhitelist 的读取键对齐）。解码失败或无 EXIF 返回 nil。
    static func exif(fromEncodedImageData data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return nil
        }
        return exif
    }
}
