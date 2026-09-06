// MARK: - AppConfig
// 职责：阈值与常量总表。tech-spec §7：全项目魔法数只允许集中在这里，
//       每项注明来源与调参入口（回归集校准流程见 docs/feasibility-report.md §2）。
// 任务卡：T04 起。

import Foundation

enum AppConfig {
    /// 扫描循环的可让出批次，避免大相册长期占满工作队列。
    static let scanBatchSize = 100

    /// Vision 请求/特征提取实现版本。请求参数或模型语义改变时递增，
    /// 即使扫描算法版本不变也必须让旧缓存失效。
    static let visionRequestVersion = 1

    /// 时间分桶间隔（秒）：间隔 ≤ 此值视作同场景连拍窗口。
    /// 来源：tech-spec §3 / TimeBucketizer 默认值冻结；调参入口：corpus 回归集。
    static let timeGapThreshold: TimeInterval = 1800

    /// 地理簇半径（米）：同场景拍摄点的经验粒度（GPS 误差 + 手抖范围量级）。
    /// 来源：可行性报告 §2.1；调参入口：真实相册标注回归集。
    static let geoClusterRadiusMeters: Double = 300

    /// pHash 汉明距离 ≤ 该值判定完全重复（直接成组，不再进 embedding 精比）。
    /// 来源：tech-spec §7，业界惯例，待回归集验证。
    static let pHashDuplicateHammingDistance = 8

    /// embedding 聚类距离阈值（L2 归一化向量的欧氏距离，取值域 [0,2]）。
    /// 初始占位值——回归集（Tools/Regression）校准前仅供 CI 冒烟。
    /// 注意 tech-spec §3 的 0.045 是 Vision 原生 distance(to:) 量纲，与本值不可混用；
    /// 校准记录见 Tools/Regression/threshold-log.md，调参必须随脚本与数据留痕。
    static let embeddingClusterDistanceThreshold = 0.6

    /// 特征计算缩略图最大边长（像素）。来源：tech-spec §1 管线输入规格。
    static let thumbnailMaxDimension = 256

    // MARK: T06 低质量检测 DSP

    /// 拉普拉斯方差归一化尺度：clarity = clamp(variance / scale, 0, 1)。
    /// 初值拍脑袋（自然图方差常在数百~数千量级），T09 回归集校准后修订。
    static let dspLaplacianNormalizationScale = 1000.0

    /// 曝光直方图阈值：亮度 ≥ 此值记过曝、≤ 此值记欠曝（8bit 灰度）。
    static let dspOverExposedLumaThreshold: UInt8 = 250
    static let dspUnderExposedLumaThreshold: UInt8 = 5

    // MARK: T06 EXIF 夜间白名单

    /// 单次曝光 ≥ 0.5s 判定为长曝夜景（夜景流水创作常见区间）。
    /// 来源：可行性报告 §2.5 误判主源分析；调参入口：人工标注对照集。
    static let exifNightMinExposureSeconds = 0.5

    /// 高感光兜底：ISO ≥ 3200 且曝光 ≥ 0.1s 也视为夜间拍摄。
    static let exifNightHighISO = 3200
    static let exifNightHighISOMinExposureSeconds = 0.1

    /// EXIF SceneCaptureType 的夜间场景枚举值（EXIF 规范 2.x 定义 3=night）。
    static let exifSceneCaptureTypeNight = 3

    // MARK: T07 大媒体清理

    /// 大媒体候选门槛（估算字节）：约 200MB——单段 4K 一分钟量级。
    /// 来源：PRD《大媒体清理》P7 页定位；调参入口：真机抽样分布。
    static let largeMediaEstimatedBytesThreshold: Int64 = 200_000_000

    // MARK: T07 体积估算系数（常量表；出处与误差预期如下）

    /// 照片压缩系数（bytes/pixel）：HEIF/JPEG 混合库经验中位，12MP 实拍 ≈ 4MB 倒推。
    /// 出处：.research/q4-filesize.json 结论（PHAsset 无公开大小 API、KVC 被否，
    /// 只能按像素估算）；误差预期 ±30%，真机抽样校准入口见 T07 验收。
    static let photoEstimatedBytesPerPixel = 0.35

    /// Live Photo 的配对视频组件与照片本体同量级 → 总体按双倍估算。
    static let livePhotoSizeMultiplier = 2.0

    /// 视频码率档位（bits/s），按最长边分辨率分档；误差预期 ±40%。
    static let videoBitrateBitsPerSecond4K: Int64 = 50_000_000
    static let videoBitrateBitsPerSecond1080p: Int64 = 18_000_000
    static let videoBitrateBitsPerSecond720p: Int64 = 9_000_000
    static let videoBitrateBitsPerSecondFallback: Int64 = 4_000_000

    /// 超长视频时长钳制（秒），防溢出式估算。
    static let videoDurationCapSeconds = 4 * 3600.0

    // MARK: T13 LLM 兜底客户端

    /// backend 代理基址（T18 接线用）。token 经构建注入（Keychain/环境），
    /// 绝不入 git；缺失时客户端自动走降级路径。
    static let llmBaseURL = URL(string: "https://api.aiphotoinbox.app")!

    /// 单次请求超时（秒）。降级铁律：超时/非 200/解析失败/断网一律回落纯规则。
    static let llmTimeoutSeconds: TimeInterval = 8
    /// 重试上限（至多 1 次重试，即最多 2 次请求）。
    static let llmMaxRetries = 1

    // MARK: T16 低质量批量页

    /// clarity 低于此值判定"模糊"候选。初值保守（自然图 clarity 多显著高于此，
    /// 糊片/纯色废片贴近 0），T16 验收的 20 张标注集校准后修订。
    static let lowQualityClarityThreshold = 0.18

    /// 过曝/欠曝判定：对应亮度像素占比 ≥ 此值。
    /// 来源：PRD P6 三分区口径；调参入口：人工标注对照集（T06 验收同源）。
    static let lowQualityOverExposedRatioThreshold = 0.30
    static let lowQualityUnderExposedRatioThreshold = 0.30

    /// 模糊与曝光异常同时命中时，达到此占比才让过曝标签压过模糊标签。
    /// 低于该值仍保留模糊/欠曝的保守分类，避免单个亮斑主导结果。
    static let lowQualityExposureDominanceRatio = 0.50

    // MARK: 安全预选

    /// 相似组最多允许自动预选的删除比例。向下取整，且 Best Shot 永不计入。
    static let maxPreselectedDeletionRatio = 0.70

    // MARK: T15 截图任务箱

    /// PDF 导出用原图采样最大边长（像素）：收据文字可读与内存占用的折中。
    static let pdfExportMaxDimension = 1600
}
