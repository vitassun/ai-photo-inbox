// MARK: - AppRoot
// 职责：App 生命周期入口（SwiftUI）。刻意保持极简：单元测试以 App 为宿主（TEST_HOST），
//       没有可启动入口 CI 的 xcodebuild test 会直接失败。后续任务卡替换占位首页。
// 任务卡：T01（工程骨架）。

import SwiftUI

@main
struct AIPhotoInboxApp: App {
    init() {
        // 启动期红线断言（T09）：常量被篡改会在 Debug 构建直接崩在启动期。
        SafetyRules.validateRedLines()
    }

    var body: some Scene {
        WindowGroup {
            DailyInboxView()   // T14：打开即见摘要首页，替换 T01 占位页
        }
    }
}
