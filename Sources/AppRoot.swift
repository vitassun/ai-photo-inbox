// MARK: - AppRoot
// 职责：App 生命周期入口（SwiftUI）。刻意保持极简：单元测试以 App 为宿主（TEST_HOST），
//       没有可启动入口 CI 的 xcodebuild test 会直接失败。后续任务卡替换占位首页。
// 任务卡：T01（工程骨架）。

import SwiftUI

@main
struct AIPhotoInboxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// 占位首页：T07/T12 接扫描仪表盘时替换。
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("AI Photo Inbox")
                .font(.headline)
            Text("骨架就绪 · 等待扫描流水线接入")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
