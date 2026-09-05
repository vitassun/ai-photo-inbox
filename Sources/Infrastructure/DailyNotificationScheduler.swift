// MARK: - DailyNotificationScheduler
// 职责：UNUserNotificationCenter 本地通知调度（T14）。
//       只用本地通知（免费签名无 APNs 推送能力）；每日固定时刻纯文字摘要；
//       通知时刻存 KeyValueStore（默认 21:00，App 内可改）。

import Foundation
import UserNotifications

final class DailyNotificationScheduler {

    static let identifier = "daily-inbox-summary"
    private static let hourKey = "inbox.notify.hour"

    private let store: KeyValueStore
    private let center: UNUserNotificationCenter

    init(store: KeyValueStore, center: UNUserNotificationCenter = .current()) {
        self.store = store
        self.center = center
    }

    /// 用户配置的通知时刻（默认 21:00）。
    var notifyHour: Int {
        get {
            guard let value = store.string(forKey: Self.hourKey).flatMap(Int.init),
                  (0...23).contains(value) else { return 21 }
            return value
        }
        set {
            guard (0...23).contains(newValue) else { return }
            store.setString(String(newValue), forKey: Self.hourKey)
        }
    }

    /// 请求授权并安排下一次每日摘要（内容按当时摘要实时生成——
    /// 本地通知用日历触发器 + 打开时刷新的兜底两条腿，V1 不做后台刷新）。
    func scheduleDailySummary(summaryBody: @escaping () -> String) {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, let self else { return }
            let content = UNMutableNotificationContent()
            content.title = "AI Photo Inbox · 今日摘要"
            content.body = summaryBody()
            content.sound = .default

            var components = DateComponents()
            components.hour = self.notifyHour
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

            // repeats 触发器内容不可变——正文以"打开时计算 + 下次打开刷新"兜底，
            // 这里安排的是固定文案骨架，实际数字由每次打开 App 时重挂更新。
            let request = UNNotificationRequest(
                identifier: Self.identifier, content: content, trigger: trigger
            )
            self.center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            self.center.add(request)
        }
    }

    /// 取消每日摘要（用户关闭通知开关时调用；不影响其余功能）。
    func cancelDailySummary() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}
