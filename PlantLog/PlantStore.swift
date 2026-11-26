import Foundation
import SwiftData

@Model final class Plant {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var interval: Int?
    var reminderStart: Int?
    var deferredFrom: Int?
    var deferredTo: Int?
    var archivedAt: Date?
    var suggestedInterval: Int?
    var milestone: [UUID]?
    var milestoneSeen = false

    init(_ record: PlantRecord) {
        id = record.id
        name = record.name
        createdAt = record.createdAt
        interval = record.interval
        reminderStart = record.reminderStart?.rawValue
        deferredFrom = record.deferredFrom?.rawValue
        deferredTo = record.deferredTo?.rawValue
        archivedAt = record.archivedAt
        suggestedInterval = record.suggestedInterval
        milestone = record.milestone
        milestoneSeen = record.milestoneSeen
    }

    func update(_ record: PlantRecord) {
        name = record.name
        interval = record.interval
        reminderStart = record.reminderStart?.rawValue
        deferredFrom = record.deferredFrom?.rawValue
        deferredTo = record.deferredTo?.rawValue
        archivedAt = record.archivedAt
        suggestedInterval = record.suggestedInterval
        milestone = record.milestone
        milestoneSeen = record.milestoneSeen
    }

    func record(events: [EventRecord]) -> PlantRecord {
        PlantRecord(id: id, name: name, createdAt: createdAt, interval: interval,
                    reminderStart: reminderStart.map(LocalDay.init(rawValue:)), deferredFrom: deferredFrom.map(LocalDay.init(rawValue:)),
                    deferredTo: deferredTo.map(LocalDay.init(rawValue:)), archivedAt: archivedAt,
                    suggestedInterval: suggestedInterval, events: events, milestone: milestone, milestoneSeen: milestoneSeen)
    }
}

@Model final class CareEvent {
    @Attribute(.unique) var id: UUID
    var plantID: UUID
    var kind: String
    var day: Int
    var createdAt: Date
    var photoID: UUID?
    var recordedOn: Int?

    init(_ record: EventRecord, plantID: UUID) {
        id = record.id
        self.plantID = plantID
        kind = record.kind.rawValue
        day = record.day.rawValue
        createdAt = record.createdAt
        photoID = record.photo?.id
        recordedOn = record.recordedOn?.rawValue
    }

    func record(photos: [UUID: PhotoRecord]) -> EventRecord? {
        guard let kind = CareKind(rawValue: kind) else { return nil }
        return EventRecord(id: id, kind: kind, day: LocalDay(rawValue: day), createdAt: createdAt,
                           photo: photoID.flatMap { photos[$0] }, recordedOn: recordedOn.map(LocalDay.init(rawValue:)))
    }
}

@Model final class PhotoAsset {
    @Attribute(.unique) var id: UUID
    var path: String
    var width: Int
    var height: Int

    init(_ record: PhotoRecord) {
        id = record.id
        path = record.path
        width = record.width
        height = record.height
    }

    var record: PhotoRecord { PhotoRecord(id: id, path: path, width: width, height: height) }
}

enum StoreError: Error { case missing, limit, invalid, staleUndo }

struct WaterUndo: Sendable {
    let event: UUID
    let plant: UUID
    let deferredFrom: LocalDay?
    let deferredTo: LocalDay?
}

enum PlantEdit: Sendable {
    case add(String, suggestedInterval: Int? = nil), rename(String), archive(Bool), delete
    case water, postpone, undo(WaterUndo), reminder(Int?)
    case log(CareKind, LocalDay, UUID?), removeEvent(UUID), photo(PhotoRecord), seeMilestone
}

@ModelActor actor PlantStore {
    static func open(root: URL) async throws -> PlantStore {
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let schema = Schema([Plant.self, CareEvent.self, PhotoAsset.self])
            let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("plants.store"), cloudKitDatabase: .none)
            return PlantStore(modelContainer: try ModelContainer(for: schema, configurations: [config]))
        }.value
    }

    func snapshot() throws -> [PlantRecord] {
        let photos = try modelContext.fetch(FetchDescriptor<PhotoAsset>())
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.record) })
        let events = Dictionary(grouping: try modelContext.fetch(FetchDescriptor<CareEvent>()), by: \.plantID)
        return try modelContext.fetch(FetchDescriptor<Plant>()).map { plant in
            plant.record(events: (events[plant.id] ?? []).compactMap { $0.record(photos: byID) })
        }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func apply(_ edit: PlantEdit, to id: UUID? = nil, now: Date, today: LocalDay, hasPro: Bool) throws -> (WaterUndo?, [String]) {
        modelContext.autosaveEnabled = false
        do {
            let result = try update(edit, to: id, now: now, today: today, hasPro: hasPro)
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func update(_ edit: PlantEdit, to id: UUID?, now: Date, today: LocalDay, hasPro: Bool) throws -> (WaterUndo?, [String]) {
        let plants = try modelContext.fetch(FetchDescriptor<Plant>())
        let canAdd = hasPro || plants.lazy.filter { $0.archivedAt == nil }.count < 3
        if case .add(let name, let suggestedInterval) = edit {
            guard canAdd else { throw StoreError.limit }
            let value = try CareTransfer(name: name, interval: suggestedInterval)
            modelContext.insert(Plant(PlantRecord(name: value.name, createdAt: now, suggestedInterval: value.interval)))
            return (nil, [])
        }
        guard let plant = plants.first(where: { $0.id == id }) else { throw StoreError.missing }
        let plantID = plant.id
        let events = try modelContext.fetch(FetchDescriptor<CareEvent>(predicate: #Predicate { $0.plantID == plantID }))
        let photos = try modelContext.fetch(FetchDescriptor<PhotoAsset>())
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.record) })
        var record = plant.record(events: events.compactMap { $0.record(photos: byID) })
        var undo: WaterUndo?
        var files: [String] = []

        func remove(_ event: CareEvent) {
            if let photoID = event.photoID, let asset = photos.first(where: { $0.id == photoID }) {
                files.append(asset.path)
                modelContext.delete(asset)
            }
            modelContext.delete(event)
        }

        switch edit {
        case .add: break
        case .rename(let name): record.name = try CareTransfer(name: name, interval: nil).name
        case .archive(let archive):
            guard archive || plant.archivedAt == nil || canAdd else { throw StoreError.limit }
            record.archivedAt = archive ? now : nil
        case .delete:
            events.forEach(remove)
            modelContext.delete(plant)
            return (nil, files)
        case .water:
            let oldFrom = record.deferredFrom
            let oldTo = record.deferredTo
            if let event = record.water(on: today, now: now) {
                modelContext.insert(CareEvent(event, plantID: plantID))
                undo = WaterUndo(event: event.id, plant: plantID, deferredFrom: oldFrom, deferredTo: oldTo)
            }
        case .postpone: record.deferCheck(on: today)
        case .seeMilestone: record.milestoneSeen = true
        case .undo(let previous):
            guard previous.plant == plantID, let event = events.first(where: { $0.id == previous.event }),
                  record.timeline.first(where: { $0.kind == .water })?.id == event.id,
                  record.deferredFrom == nil else { throw StoreError.staleUndo }
            remove(event)
            record.deferredFrom = previous.deferredFrom
            record.deferredTo = previous.deferredTo
        case .reminder(let interval):
            guard interval.map({ (1...365).contains($0) }) ?? true else { throw StoreError.invalid }
            if interval != record.interval {
                record.reminderStart = interval == nil ? nil : (record.reminderStart ?? today)
                record.interval = interval
                record.deferredFrom = nil
                record.deferredTo = nil
            }
        case .log(let kind, let day, let eventID):
            guard day <= today else { throw StoreError.invalid }
            if let eventID {
                guard let event = events.first(where: { $0.id == eventID }), (event.photoID != nil) == (kind == .photo) else { throw StoreError.missing }
                event.kind = kind.rawValue
                event.day = day.rawValue
            } else {
                guard kind != .photo else { throw StoreError.invalid }
                modelContext.insert(CareEvent(EventRecord(kind: kind, day: day, createdAt: now, recordedOn: today), plantID: plantID))
            }
        case .removeEvent(let eventID):
            guard let event = events.first(where: { $0.id == eventID }) else { throw StoreError.missing }
            remove(event)
        case .photo(let photo):
            modelContext.insert(PhotoAsset(photo))
            let event = EventRecord(kind: .photo, day: today, createdAt: now, photo: photo, recordedOn: today)
            modelContext.insert(CareEvent(event, plantID: plantID))
            record.events.append(event)
            record.recordMilestone()
        }
        plant.update(record)
        return (undo, files)
    }

    func seed(_ records: [PlantRecord]) throws {
        guard try snapshot().isEmpty else { return }
        for record in records {
            modelContext.insert(Plant(record))
            for event in record.events {
                if let photo = event.photo { modelContext.insert(PhotoAsset(photo)) }
                modelContext.insert(CareEvent(event, plantID: record.id))
            }
        }
        try modelContext.save()
    }
}
