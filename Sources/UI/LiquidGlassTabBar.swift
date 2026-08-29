// MARK: - LiquidGlassTabBar
// 职责：底部液态玻璃风格 Tab 指示器——半透明模糊背景 + 浮动高亮滑块 + 图标。
//        iOS 26 Liquid Glass 简化模拟：ultraThinMaterial + 圆角胶囊 + 弹性滑动。

import SwiftUI

/// 底部液态玻璃 Tab 栏：三个图标 + 浮动高亮胶囊，支持手势切换。
struct LiquidGlassTabBar: View {
    @Binding var selected: Int

    /// Tab 定义（图标 + 标题）。
    let tabs: [(icon: String, title: String)]

    /// 胶囊水平偏移动画。
    @Namespace private var namespace
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                tabButton(index: index, tab: tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(.horizontal, 56)
        .padding(.bottom, 8)
    }

    private func tabButton(index: Int, tab: (icon: String, title: String)) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
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
            .background {
                if selected == index {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.7)
                        .matchedGeometryEffect(id: "tab_indicator", in: namespace)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 全局容器：将内容 + 液态玻璃 Tab 栏组合。
struct LiquidGlassTabContainer<Content: View>: View {
    @Binding var selectedTab: Int
    let tabs: [(icon: String, title: String)]
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景渐变铺满。
            Theme.backgroundGradient
                .ignoresSafeArea()

            // 内容区。
            content(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部液态玻璃 Tab 栏。
            LiquidGlassTabBar(selected: $selectedTab, tabs: tabs)
                .padding(.bottom, 4)
        }
    }
}
