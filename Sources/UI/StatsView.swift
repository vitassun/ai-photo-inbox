// MARK: - StatsView
// 职责：统计页占位（底部 Tab 之一）。展示已节省空间、周趋势柱状图等。
//        后续任务卡填充真实数据。

import SwiftUI

struct StatsView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                savedSpaceCard
                weeklyChart
                categoryBreakdown
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 100)
        }
    }

    // MARK: - 标题

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("统计")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.titleText)
            Text("整理成果一目了然")
                .font(.subheadline)
                .foregroundStyle(Theme.subtitleText)
        }
    }

    // MARK: - 已节省空间卡片

    private var savedSpaceCard: some View {
        HStack(spacing: 16) {
            // 环形进度
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: 0.87)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accentBlue, Theme.accentGreen],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("87%")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.titleText)
            }
            .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: 6) {
                Text("本月已节省空间")
                    .font(.subheadline)
                    .foregroundStyle(Theme.subtitleText)
                Text("约 12.4 GB")
                    .font(.title.bold())
                    .foregroundStyle(Theme.titleText)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.caption2)
                    Text("较上月 +3.2 GB")
                        .font(.caption)
                }
                .foregroundStyle(Theme.accentGreen)
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    // MARK: - 周趋势柱状图

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("周趋势")
                .font(.headline)
                .foregroundStyle(Theme.titleText)

            HStack(alignment: .bottom, spacing: 20) {
                ForEach(weekData, id: \.label) { item in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accentBlue, Theme.accentBlue.opacity(0.5)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 32, height: CGFloat(item.value) * 100)

                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(Theme.captionText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
            .padding(.vertical, 8)
        }
        .padding(20)
        .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    // MARK: - 分类统计

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("清理分类")
                .font(.headline)
                .foregroundStyle(Theme.titleText)

            ForEach(categories, id: \.label) { cat in
                HStack(spacing: 12) {
                    Image(systemName: cat.icon)
                        .font(.body)
                        .foregroundStyle(cat.color)
                        .frame(width: 28)

                    Text(cat.label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.bodyText)

                    Spacer()

                    Text(cat.count)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.subtitleText)
                }
                .padding(.vertical, 6)

                if cat.label != categories.last?.label {
                    Divider().background(Color.white.opacity(0.08))
                }
            }
        }
        .padding(20)
        .background(Theme.sectionBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    // MARK: - 示例数据

    private struct WeekItem {
        let label: String
        let value: Double
    }

    private let weekData: [WeekItem] = [
        .init(label: "1周前", value: 0.3),
        .init(label: "上周", value: 0.7),
        .init(label: "本周", value: 0.5),
    ]

    private struct CategoryItem {
        let icon: String
        let label: String
        let count: String
        let color: Color
    }

    private let categories: [CategoryItem] = [
        .init(icon: "photo.on.rectangle", label: "重复照片", count: "156", color: Theme.accentBlue),
        .init(icon: "camera.badge.ellipsis", label: "低质量照片", count: "23", color: Theme.accentOrange),
        .init(icon: "video.badge.waveform", label: "大视频文件", count: "12", color: Theme.accentGreen),
        .init(icon: "arrow.trash", label: "已清理", count: "89", color: Theme.accentRed),
    ]
}
