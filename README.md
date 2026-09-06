# AI Photo Inbox — iOS 工程

iOS 相册整理 App（深度清理 + Daily Inbox + 截图任务管家）。扫描、建议、
删除确认和本地持久化均已接入，真机相册权限与 PhotoKit 确认框仍需在设备上验收。
产品与可行性全貌见 `../docs/feasibility-report.md`；本 README 只讲工程怎么跑。

## 目录结构

```
ios/
├── project.yml                  # XcodeGen 工程定义（唯一需要手改的工程文件）
├── Sources/
│   ├── AppRoot.swift            # SwiftUI 入口（测试宿主必需，保持极简）
│   ├── Core/                    # ★ 纯逻辑层：绝不 import Photos/Vision/UIKit
│   │   ├── Models/              # AssetRecord / CandidateGroup / ScanPhase / Verdict
│   │   ├── Safety/              # SafetyRules —— 删除安全红线（T10）
│   │   ├── Grouping/            # TimeBucketizer —— 时间分桶（T04）
│   │   ├── Scoring/             # KeepScore —— 保留分引擎（T06）
│   │   ├── Scanning/            # ScanStateMachine —— 可恢复扫描状态机（T07）
│   │   └── Protocols/           # KeyValueStore / PhotoLibraryService / VisionAnalysisService
│   └── Infrastructure/          # PhotoKit/Vision 适配层：允许 import 框架
│       ├── SystemPhotoLibraryService.swift   (T02/T10)
│       └── VisionAnalysisService.swift       (T05)
├── Tests/                       # 纯逻辑单测，CI 模拟器可跑，无需真机
└── .github/workflows/ios.yml    # macOS runner：xcodegen → xcodebuild test
```

**分层铁律**：`Core/` 下任何文件出现 `import Photos`、`import Vision`、`import UIKit`
即为架构违规。所有系统能力经 `Protocols/` 抽象注入；这让分组算法、评分引擎、
状态机、安全规则全部能在 CI 的模拟器上验证，不依赖真机相册。

## 为什么用 XcodeGen（而不是手写 pbxproj）

- `project.pbxproj` 是机器生成物，手写极易冲突且 diff 不可读；
- 本项目在 Windows 上开发、没有 Mac，**文本格式的 project.yml 是唯一能被
  非 Xcode 环境可靠维护的工程定义**；
- 加文件不用改工程：`Sources/`、`Tests/` 整目录自动纳入 target。

用法：

```bash
brew install xcodegen        # macOS 上一次性安装
cd ios && xcodegen generate  # 生成 AIPhotoInbox.xcodeproj（已 gitignore）
open AIPhotoInbox.xcodeproj
```

注意：`SWIFT_VERSION` 是"语言模式"，合法值只有 4.0/4.2/5.0/6.0——
我们说的"Swift 5.9 语法"对应语言模式 `5.0`（由 Xcode 15/16 编译器提供），
project.yml 里因此写的是 `5.0`，写 `5.9` 会直接构建失败。

## 本地无 Mac 的开发循环

本仓库日常在 Windows 上写代码，编译与测试完全交给 GitHub Actions：

1. 本地改 Swift 文件（VS Code + Swift 插件获得语法高亮即可）；
2. push 到 `main`（或开 PR）→ Actions 的 `ios-ci` 自动跑：
   `checkout → brew install xcodegen → xcodegen generate → xcodebuild test`；
3. 红了就点进日志找第一个 error（后面的级联错误不用看），修完再 push。

**首次 CI 大概率报小错——这是预期内的，按日志迭代就是任务卡 T01 的正常工作方式。**
常见首跑问题对照：

| 日志症状 | 处置 |
|---|---|
| `Unable to find a device matching ... iPhone 16` | runner 镜像更新换代了，把 destination 里的机型名换成 `simctl list devices available` 里实际存在的 |
| `SWIFT_VERSION 'x' is unsupported` | 语言模式只能 4.0/4.2/5.0/6.0，别写编译器版本号 |
| 测试宿主启动失败 | 检查 App 是否有 `@main` 入口（AppRoot.swift 不许删） |
| signing 报错 | 模拟器构建不需要证书；设备构建由 CI 使用 `CODE_SIGNING_ALLOWED=NO` |

## 当前验收状态

- 删除红线：收藏、编辑过、组内没有直接替代、用户保留的资产不会自动预选；视频和
  Live Photo 只展示并允许用户逐张选择。所有删除都经过 PhotoKit 系统确认框。
- 恢复安全：保留记录、资产修改时间、特征算法版本和 Vision 请求版本均参与建议复核；
  无法确认安全数据或特征新鲜度时暂停/收窄建议。
- 持久化：扫描结果通过单事务快照保存，快照不包含 GPS；写入失败会暂停并显示错误。
  相册局部变更只失效相关组，其他结果继续保留。
- 评测：运行 `python3 Tools/Regression/run_regression.py <dataset_dir>`。数据集只放在
  本地，脚本检查正负例、标注 ID、向量覆盖率和维度，并将漏拆率纳入达标条件。
- 真机待验收：权限缩小、后台恢复、全选后收藏/编辑、替代资产被删除、部分删除批次
  取消，以及视频/Live Photo 播放预览。

## 真机安装：Sideloadly + 免费 Apple ID（无开发者账号路线）

V1 自用/内测不需要 $99/年 的开发者账号：

1. Windows 装 [Sideloadly](https://sideloadly.io/)，数据线连 iPhone；
2. 拖入 CI 产出的 `.ipa`（或未签名的 `.app` 打包），填你的 Apple ID；
3. 手机上 设置 → 通用 → VPN 与设备管理 → 信任该证书；
4. **免费签名 7 天过期**：到期后重新用 Sideloadly 签一次即可（App 数据一般保留，
   重要阶段先备份）；免费账号同时最多 3 个侧载 App。
5. 注意：删除相册能力需要真机实测（T10），模拟器相册库是空的，别拿它验收 PhotoKit 行为。

## 安全红线（改动任何相关代码前必读）

1. 收藏过的照片/视频**永不预选删除**；
2. 用户编辑过的资产**永不预选删除**；
3. 组内唯一（无相似替代）的资产**永不预选删除**；
4. **永不静默删除**：一切删除走 `PHPhotoLibrary.performChanges` 系统确认框，用户逐次批准。

落点：`Sources/Core/Safety/SafetyRules.swift`（常量 + 判定），
验收：`Tests/SafetyRulesTests.swift`。让该测试变红的 PR 一律拒绝。

## 任务卡对照

> 权威任务索引（含规模/依赖，T01–T14）见 `../tasks/README.md`；本表只标本仓库骨架落点。

| 卡 | 内容 | 骨架落点 |
|---|---|---|
| T01 | 项目骨架与 CI 绿灯 | project.yml / .github/workflows/ios.yml / 全部测试 |
| T02 | 授权与资产拉取层（含变更监听） | Infrastructure/SystemPhotoLibraryService.swift |
| T03 | 扫描状态机接入真实管线 + GRDB 持久化 | ScanningEngine + PhotoLibraryDatabase |
| T04 | 时间地理分桶 + pHash 粗筛 | Core/Grouping/* + Infrastructure/PerceptualHash.swift |
| T05 | FeaturePrint 聚类 + 阈值回归集 | Infrastructure/VisionAnalysisService.swift + Tools/Regression |
| T06 | 低质量检测 DSP + EXIF 夜间白名单 | Core/Quality/ImageQualityDSP.swift |
| T07 | 大媒体估算模型 + LivePhoto 配对 | Core/Media/* |
| T08 | Best Shot 特征整合（人脸/显著性/美学） | VisionAnalysisService + ScanningEngine scoring |
| T09 | 保留分引擎接线 + SafetyRules 集成 | GroupScoring + SafetyRules |
| T10 | 安全删除流（确认框/批量 UI/教育页） | DeletionCoordinator + SystemPhotoLibraryService |
