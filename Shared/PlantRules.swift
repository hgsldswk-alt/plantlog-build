import Foundation

struct LocalDay: Codable, Hashable, Comparable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }
    init(_ date: Date, zone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = (parts.year ?? 1) * 10000 + (parts.month ?? 1) * 100 + (parts.day ?? 1)
    }

    func components(hour: Int) -> DateComponents {
        DateComponents(year: rawValue / 10000, month: rawValue / 100 % 100, day: rawValue % 100, hour: hour, minute: 0, second: 0)
    }

    func date(hour: Int = 12, zone: TimeZone = .autoupdatingCurrent) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components(hour: hour)) ?? .distantPast
    }

    func adding(_ days: Int) -> LocalDay {
        let utc = TimeZone(secondsFromGMT: 0)!
        return LocalDay(date(zone: utc).addingTimeInterval(Double(days) * 86400), zone: utc)
    }

    var formatted: String { date().formatted(.dateTime.year().month(.abbreviated).day()) }
    var shortLabel: String { date().formatted(.dateTime.month(.abbreviated).day()) }
    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum CareKind: String, Codable, CaseIterable, Sendable {
    case water, repot, bloom, photo
    var label: String {
        switch self {
        case .water: L.t("浇水")
        case .repot: L.t("换盆")
        case .bloom: L.t("开花")
        case .photo: L.t("照片")
        }
    }
    var icon: String {
        switch self {
        case .water: "drop"
        case .repot: "leaf"
        case .bloom: "camera.macro"
        case .photo: "photo"
        }
    }
}

struct PhotoRecord: Hashable, Sendable {
    let id: UUID
    let path: String
    let width: Int
    let height: Int
}

struct EventRecord: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: CareKind
    var day: LocalDay
    var createdAt: Date
    var photo: PhotoRecord?
    var recordedOn: LocalDay?

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.day != rhs.day { return lhs.day > rhs.day }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

struct PlantRecord: Identifiable, Sendable {
    var id = UUID()
    var name: String
    var createdAt: Date
    var interval: Int?
    var reminderStart: LocalDay?
    var deferredFrom: LocalDay?
    var deferredTo: LocalDay?
    var archivedAt: Date?
    var suggestedInterval: Int?
    var events: [EventRecord] = []
    var milestone: [UUID]?
    var milestoneSeen: Bool = false

    var timeline: [EventRecord] { events.sorted(by: EventRecord.newestFirst) }
    var lastWater: LocalDay? { events.lazy.filter { $0.kind == .water }.map(\.day).max() }
    var cover: PhotoRecord? { timeline.compactMap(\.photo).first }

    var nextCheck: LocalDay? {
        guard archivedAt == nil, let interval, let base = lastWater ?? reminderStart else { return nil }
        if let deferredFrom, let deferredTo, (lastWater ?? base) <= deferredFrom { return deferredTo }
        return base.adding(interval)
    }

    func isDue(on day: LocalDay) -> Bool { nextCheck.map { $0 <= day } ?? false }

    mutating func deferCheck(on day: LocalDay) {
        guard isDue(on: day) else { return }
        deferredFrom = day
        deferredTo = day.adding(1)
    }

    @discardableResult mutating func water(on day: LocalDay, now: Date) -> EventRecord? {
        guard !events.contains(where: { $0.kind == .water && $0.day == day && abs(now.timeIntervalSince($0.createdAt)) < 2 }) else { return nil }
        deferredFrom = nil
        deferredTo = nil
        let event = EventRecord(kind: .water, day: day, createdAt: now, recordedOn: day)
        events.append(event)
        return event
    }

    var comparison: [EventRecord] {
        let photos = timeline.filter { $0.photo != nil }
        guard photos.count >= 2 else { return [] }
        return Array(photos.prefix(2).reversed())
    }

    mutating func recordMilestone() {
        guard milestone == nil, comparison.count == 2 else { return }
        milestone = comparison.map(\.id)
    }

    static func dueFirst(_ plants: [Self], on day: LocalDay) -> [UUID] {
        plants.compactMap { plant -> (LocalDay, UUID)? in
            guard let check = plant.nextCheck, check <= day else { return nil }
            return (check, plant.id)
        }.sorted { ($0.0, $0.1.uuidString) < ($1.0, $1.1.uuidString) }.map(\.1)
    }
}
