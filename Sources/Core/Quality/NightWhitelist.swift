// MARK: - NightWhitelist
// 职责：EXIF 夜间长曝白名单——夜景/长曝照片豁免"低亮度=低质"惩罚，
//       避免夜景照被系统性判低质（可行性报告 §2.5）。
// 任务卡：T06。纯字典逻辑，键名对齐 CGImagePropertyExifXXX 属性字符串，
//       Infrastructure 解出 EXIF 字典后原样透传，本层不 import 图像框架。
//
// 边界：白名单只豁免质量惩罚；安全红线永远独立生效，不受任何豁免影响。

import Foundation

enum NightWhitelist {

    /// 是否夜间/长曝拍摄（命中任一判据即豁免）：
    ///   1. SceneCaptureType == night（EXIF 规范值 3）；
    ///   2. 单次曝光 ≥ exifNightMinExposureSeconds；
    ///   3. 高 ISO 且曝光 ≥ exifNightHighISOMinExposureSeconds。
    /// 字典缺失/类型不符按"非夜间"处理（保守默认，不豁免）。
    static func isNightLongExposure(_ exif: [String: Any]) -> Bool {
        if sceneCaptureType(exif) == AppConfig.exifSceneCaptureTypeNight {
            return true
        }
        guard let exposure = exposureSeconds(exif) else { return false }
        if exposure >= AppConfig.exifNightMinExposureSeconds {
            return true
        }
        if let iso = isoRating(exif),
           iso >= AppConfig.exifNightHighISO,
           exposure >= AppConfig.exifNightHighISOMinExposureSeconds {
            return true
        }
        return false
    }

    // MARK: 字段提取（EXIF 数值可能以 NSNumber/Int/Double 多种形态出现）

    private static func sceneCaptureType(_ exif: [String: Any]) -> Int? {
        number(exif["SceneCaptureType"])?.intValue
    }

    private static func exposureSeconds(_ exif: [String: Any]) -> Double? {
        number(exif["ExposureTime"])?.doubleValue
    }

    private static func isoRating(_ exif: [String: Any]) -> Int? {
        if let array = exif["ISOSpeedRatings"] as? [Any] {
            return array.first.flatMap { number($0)?.intValue }
        }
        return number(exif["ISOSpeedRatings"])?.intValue
            ?? number(exif["ISOSpeed"])?.intValue
    }

    private static func number(_ value: Any?) -> NSNumber? {
        switch value {
        case let numeric as NSNumber: return numeric
        case let string as String: return NumberFormatter().number(from: string)
        default: return nil
        }
    }
}
