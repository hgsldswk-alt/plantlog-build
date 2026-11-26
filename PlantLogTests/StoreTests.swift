import Foundation
import XCTest

final class StoreTests: XCTestCase {
    func testWaterUndoRestoresDeferredDayAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = LocalDay(rawValue: 20261119)
        let now = day.date(hour: 10)
        let plant = PlantRecord(name: "Fern", createdAt: now, interval: 7, reminderStart: day.adding(-7))
        let store = try await PlantStore.open(root: root)
        try await store.seed([plant])
        _ = try await store.apply(.postpone, to: plant.id, now: now, today: day, hasPro: false)
        let watered = try await store.apply(.water, to: plant.id, now: now, today: day, hasPro: false)
        let undo = try XCTUnwrap(watered.0)
        let stored = try await store.snapshot().first
        XCTAssertEqual(stored?.nextCheck, day.adding(7))
        _ = try await store.apply(.undo(undo), to: plant.id, now: now, today: day, hasPro: false)
        let reopened = try await PlantStore.open(root: root)
        let restored = try await reopened.snapshot().first
        XCTAssertEqual(restored?.nextCheck, day.adding(1))
        XCTAssertTrue(restored?.events.isEmpty == true)
    }

    func testExpiredKeepsFiveWritableAndBlocksNewPlant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = LocalDay(rawValue: 20261119)
        let now = day.date()
        let plants = (1...5).map { PlantRecord(name: "Plant \($0)", createdAt: now) }
        let store = try await PlantStore.open(root: root)
        try await store.seed(plants)
        for plant in plants {
            _ = try await store.apply(.water, to: plant.id, now: now, today: day, hasPro: false)
            _ = try await store.apply(.reminder(7), to: plant.id, now: now, today: day, hasPro: false)
        }
        do {
            _ = try await store.apply(.add("Sixth"), now: now, today: day, hasPro: false)
            XCTFail("Expired plan incorrectly accepts a sixth plant")
        } catch StoreError.limit {}
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertTrue(snapshot.allSatisfy { $0.lastWater == day && $0.nextCheck == day.adding(7) })
    }
}
