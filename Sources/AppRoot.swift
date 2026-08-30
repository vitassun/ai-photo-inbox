// MARK: - AppRoot
// 职责：App 生命周期入口（SwiftUI）。TabView 结构含液态玻璃底部导航栏。
//       任务卡：T01（工程骨架）。

import SwiftUI

@main
struct AIPhotoInboxApp: App {
    init() {
        SafetyRules.validateRedLines()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

/// 根视图：两 Tab 结构（首页 / 我的）+ 液态玻璃底部导航栏。
struct RootTabView: View {
    @State private var selectedTab = 0

    private let tabs: [(icon: String, title: String)] = [
        (icon: "house.fill", title: "首页"),
        (icon: "person.fill", title: "我的"),
    ]

    var body: some View {
        LiquidGlassTabContainer(selectedTab: $selectedTab, tabs: tabs) { tab in
            switch tab {
            case 0:
                NavigationStack {
                    DailyInboxView()
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .toolbarColorScheme(.dark, for: .navigationBar)
                }
            case 1:
                ProfileView(environment: AppEnvironment.shared)
            default:
                DailyInboxView()
            }
        }
        .preferredColorScheme(.dark)
    }
}
