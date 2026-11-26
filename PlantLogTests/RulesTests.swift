import Foundation
import XCTest

final class RulesTests: XCTestCase {
    private let today = LocalDay(rawValue: 20261119)
    private let open = Date(timeIntervalSince1970: 1_790_000_000)

    func testTrialIsExclusiveAtDayThirtyAndClockRollbackDoesNotReopenIt() {
        var trial = Entitlement(firstOpen: open)
        XCTAssertTrue(trial.hasPro(at: open.addingTimeInterval(29 * 86400), free: false))
        XCTAssertFalse(trial.hasPro(at: trial.trialEnd, free: false))
        trial.observe(trial.trialEnd)
        XCTAssertFalse(trial.hasPro(at: open.addingTimeInterval(29 * 86400), free: false))
        XCTAssertTrue(trial.hasPro(at: trial.trialEnd, free: true))
    }

    func testTrialReceiptAndRefundDoNotRestartTrial() {
        var trial = Entitlement(firstOpen: open)
        trial.reconcile(purchased: true, receiptDate: open.addingTimeInterval(10 * 86400))
        XCTAssertEqual(trial.trialStart, open)
        XCTAssertTrue(trial.hasPro(at: trial.trialEnd, free: false))
        trial.reconcile(purchased: false, receiptDate: open.addingTimeInterval(-10 * 86400))
        XCTAssertEqual(trial.trialStart, open.addingTimeInterval(-10 * 86400))
        trial.reconcile(purchased: nil, receiptDate: open)
        XCTAssertEqual(trial.trialStart, open.addingTimeInterval(-10 * 86400))
        XCTAssertFalse(trial.hasPro(at: trial.trialEnd, free: false))
        XCTAssertTrue(trial.canAdd(activeCount: 2, at: trial.trialEnd, free: false))
        XCTAssertFalse(trial.canAdd(activeCount: 3, at: trial.trialEnd, free: false))
        XCTAssertFalse(trial.canAdd(activeCount: 5, at: trial.trialEnd, free: false))
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testReviewUsesAgeDistinctCareDaysAndOneAttempt() {
        var trial = Entitlement(firstOpen: open)
        let days: Set<LocalDay> = [today, today.adding(-1), today.adding(-2)]
        XCTAssertFalse(trial.canReview(at: open.addingTimeInterval(6 * 86400), careDays: days, free: false))
        XCTAssertFalse(trial.canReview(at: open.addingTimeInterval(7 * 86400), careDays: [today], free: false))
        XCTAssertTrue(trial.canReview(at: open.addingTimeInterval(7 * 86400), careDays: days, free: false))
        XCTAssertFalse(trial.canReview(at: trial.trialEnd, careDays: days, free: false))
        trial.requestedReview = true
        XCTAssertFalse(trial.canReview(at: open.addingTimeInterval(8 * 86400), careDays: days, free: false))
    }

    func testWaterBackfillAndDeferredChecks() {
        var plant = PlantRecord(name: "Plant", createdAt: open)
        XCTAssertNil(plant.nextCheck)
        plant.interval = 7
        plant.reminderStart = today.adding(-7)
        XCTAssertEqual(plant.nextCheck, today)
        plant.deferCheck(on: today)
        XCTAssertEqual(plant.nextCheck, today.adding(1))
        plant.events.append(EventRecord(kind: .water, day: today, createdAt: open.addingTimeInterval(-20)))
        XCTAssertEqual(plant.nextCheck, today.adding(1))
        XCTAssertNotNil(plant.water(on: today, now: open))
        XCTAssertNil(plant.water(on: today, now: open.addingTimeInterval(1)))
        XCTAssertEqual(plant.nextCheck, today.adding(7))
        plant.events.append(EventRecord(kind: .water, day: today.adding(-3), createdAt: open))
        XCTAssertEqual(plant.nextCheck, today.adding(7))
        plant.archivedAt = open
        XCTAssertNil(plant.nextCheck)
    }

    func testDatesAcrossMidnightTimeZonesAndDST() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T15:00:00Z"))
        XCTAssertEqual(LocalDay(timestamp.addingTimeInterval(-60), zone: tokyo), today)
        XCTAssertEqual(LocalDay(timestamp, zone: tokyo), today.adding(1))
        XCTAssertEqual(LocalDay(timestamp, zone: newYork), today)
        let march = LocalDay(rawValue: 20260307)
        XCTAssertEqual(march.adding(1).date(hour: 9, zone: newYork).timeIntervalSince(march.date(hour: 9, zone: newYork)), 23 * 3600)
    }

    func testLatestTwoPhotosMayBeAcrossMonthsOrOnSameDay() {
        var first = PlantRecord(name: "Plant", createdAt: open)
        func photo(_ day: LocalDay, at offset: TimeInterval) -> EventRecord {
            EventRecord(kind: .photo, day: day, createdAt: open.addingTimeInterval(offset),
                        photo: PhotoRecord(id: UUID(), path: "photo.jpg", width: 200, height: 300))
        }
        let previous = photo(today.adding(-40), at: 0)
        let recent = photo(today, at: 1)
        let newest = photo(today, at: 2)
        first.events = [recent]
        XCTAssertTrue(first.comparison.isEmpty)
        first.events.append(previous)
        first.recordMilestone()
        XCTAssertEqual(first.comparison.map(\.id), [previous.id, recent.id])
        first.events.append(newest)
        first.recordMilestone()
        XCTAssertEqual(first.comparison.map(\.id), [recent.id, newest.id])
        XCTAssertEqual(first.milestone, [previous.id, recent.id])
    }

    func testCareCodeAndFileShareOnlyAllowListedData() throws {
        let care = try CareTransfer(name: " Fern ", interval: 365)
        XCTAssertEqual(care.name, "Fern")
        XCTAssertEqual(try CareTransfer.parse(care.code()), care)
        let code = try care.code()
        XCTAssertEqual(try CareTransfer.parse("Here are its soil-check settings\r\n\(code)"), care)
        XCTAssertThrowsError(try CareTransfer.parse("\(code)\n\(code)"))
        XCTAssertEqual(try CareTransfer.decode(care.data()), care)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: care.data()) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["name", "version", "interval"])
        XCTAssertNoThrow(try CareTransfer(name: "Fern", interval: nil))
        XCTAssertNoThrow(try CareTransfer(name: "Fern", interval: 1))
        for invalid in [0, -1, 366] { XCTAssertThrowsError(try CareTransfer(name: "Fern", interval: invalid)) }
        XCTAssertThrowsError(try CareTransfer(name: "", interval: nil))
        XCTAssertThrowsError(try CareTransfer(name: String(repeating: "a", count: 41), interval: nil))
        XCTAssertThrowsError(try CareTransfer.parse("PLANTCARE1:???"))
        XCTAssertThrowsError(try CareTransfer.decode(Data(repeating: 65, count: 2049)))
        XCTAssertThrowsError(try CareTransfer.decode(Data(#"{"version":2,"name":"Fern"}"#.utf8)))
        XCTAssertThrowsError(try CareTransfer.decode(Data(#"{"version":1,"name":"Fern","photos":[]}"#.utf8)))
    }
}
