import Foundation
import UserNotifications

actor Reminders {
    private var generation = 0
    private let prefix = "plant-check-"

    func authorize() async {
        guard !Launch.testing else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func reconcile(_ plants: [PlantRecord], now: Date, zone: TimeZone = .autoupdatingCurrent) async {
        guard !Launch.testing else { return }
        generation += 1
        let sequence = generation
        let today = LocalDay(now, zone: zone)
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let pending = await center.pendingNotificationRequests()
        guard sequence == generation else { return }
        let wanted = plants.compactMap { plant -> (PlantRecord, LocalDay)? in
            guard let day = plant.nextCheck, day >= today, day.date(hour: 9, zone: zone) > now else { return nil }
            return (plant, day)
        }.sorted { ($0.1, $0.0.id.uuidString) < ($1.1, $1.0.id.uuidString) }
        let allowed = status == .authorized || status == .provisional || status == .ephemeral
        let limit = max(0, 60 - pending.filter { !$0.identifier.hasPrefix(prefix) }.count)
        let targets = allowed ? Array(wanted.prefix(limit)) : []
        let ids = Set(targets.map { prefix + $0.0.id.uuidString })
        let removed = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !ids.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: removed)
        for (plant, day) in targets {
            guard sequence == generation else { return }
            let content = UNMutableNotificationContent()
            content.title = L.t("检查盆土")
            content.body = L.f("看看%@的盆土，再决定要不要浇水。", plant.name)
            content.sound = .default
            content.userInfo = ["plantID": plant.id.uuidString]
            var components = day.components(hour: 9)
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = zone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: prefix + plant.id.uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
