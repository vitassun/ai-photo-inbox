// MARK: - LiquidGlassTabBar
// 职责：底部液态玻璃风格 Tab 指示器——半透明模糊背景 + 可跟手的高亮滑块 + 图标。
//        使用 ultraThinMaterial 模拟液态玻璃，并支持点按与左右拖动切换。

import SwiftUI

/// 底部液态玻璃 Tab 栏：图标 + 浮动高亮胶囊，支持点按与手势切换。
struct LiquidGlassTabBar: View {
    @Binding var selected: Int

    /// Tab 定义（图标 + 标题）。
    let tabs: [(icon: String, title: String)]

    /// 拖动过程中的指示器位移；手指松开后回到选中 Tab 的中心。
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let tabCount = max(tabs.count, 1)
            let itemWidth = max((proxy.size.width - 12) / CGFloat(tabCount), 1)
            let selectedIndex = min(max(selected, 0), tabCount - 1)
            let dragLimit = itemWidth
            let visibleDrag = min(max(dragOffset, -dragLimit), dragLimit)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)

                // 指示器直接跟随 dragOffset 移动，松手后由 selected 的更新完成吸附。
                Capsule()
                    .fill(Theme.tabBarIndicator)
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                    }
                    .shadow(color: .white.opacity(dragOffset == 0 ? 0.08 : 0.18), radius: 8)
                    .frame(width: itemWidth, height: 54)
                    .offset(x: 6 + CGFloat(selectedIndex) * itemWidth + visibleDrag)

                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        tabButton(index: index, tab: tab)
                            .frame(width: itemWidth)
                    }
                }
                .padding(6)
            }
            .contentShape(Capsule())
            .simultaneousGesture(dragGesture(itemWidth: itemWidth))
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .frame(height: 66)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(.horizontal, 56)
        .padding(.bottom, 8)
    }

    private func tabButton(index: Int, tab: (icon: String, title: String)) -> some View {
        Button {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.82)) {
                selected = index
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: selected == index ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected == index ? Color.white : Color.white.opacity(0.5))
                    .frame(height: 24)

                Text(tab.title)
                    .font(.system(size: 10, weight: selected == index ? .medium : .regular))
                    .foregroundStyle(selected == index ? Color.white : Color.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func dragGesture(itemWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                state = min(max(value.translation.width, -itemWidth), itemWidth)
            }
            .onEnded { value in
                let threshold = itemWidth * 0.25
                let direction: Int
                if value.translation.width > threshold {
                    direction = 1
                } else if value.translation.width < -threshold {
                    direction = -1
                } else {
                    direction = 0
                }

                let next = min(max(selected + direction, 0), max(tabs.count - 1, 0))
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.82)) {
                    selected = next
                }
            }
    }
}

/// 根级 TabBar 状态：导航到清理详情页时暂时隐藏底部导航，避免和返回导航冲突。
final class RootTabBarState: ObservableObject {
    @Published var isHidden = false
}

/// 全局容器：将内容 + 液态玻璃 Tab 栏组合。
struct LiquidGlassTabContainer<Content: View>: View {
    @Binding var selectedTab: Int
    let tabs: [(icon: String, title: String)]
    @ViewBuilder let content: (Int) -> Content
    @StateObject private var tabBarState = RootTabBarState()

    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景渐变铺满。
            Theme.backgroundGradient
                .ignoresSafeArea()

            // 内容区。
            content(selectedTab)
                .environmentObject(tabBarState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部液态玻璃 Tab 栏。
            if !tabBarState.isHidden {
                LiquidGlassTabBar(selected: $selectedTab, tabs: tabs)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tabBarState.isHidden)
        .onChange(of: selectedTab) { _ in
            // 切换到另一个根 Tab 时，确保导航栏恢复可见。
            tabBarState.isHidden = false
        }
    }
}
