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

/// 根视图：使用系统 TabView 承载首页 / 我的。
///
/// iOS 26 会为系统 TabView 自动提供苹果原生 Liquid Glass 材质与交互；
/// 在较早系统上则使用系统自己的兼容样式。清理详情页通过
/// `.toolbar(.hidden, for: .tabBar)` 隐藏这条系统栏，避免底部导航遮挡内容。
struct RootTabView: View {
    @State private var selectedTab = 0
    @StateObject private var tabBarState = RootTabBarState()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DailyInboxView()
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
            }
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }
            .tag(0)

            NavigationStack {
                ProfileView(environment: AppEnvironment.shared)
                    .toolbarColorScheme(.dark, for: .navigationBar)
            }
            .tabItem {
                Label("我的", systemImage: "person.fill")
            }
            .tag(1)
        }
        .environmentObject(tabBarState)
        .preferredColorScheme(.dark)
    }
}
