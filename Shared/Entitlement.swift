import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var latestSeen: Date?
    var disclosedTrial = false
    var requestedReview = false
    var coreReviewProgress: CoreReviewProgress?

    var trialStart: Date { proStartedAt ?? firstOpen }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86400) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart && max(now, latestSeen ?? now) < trialEnd)
    }

    func canAdd(activeCount: Int, at now: Date, free: Bool = Launch.isFree) -> Bool {
        activeCount < 3 || hasPro(at: now, free: free)
    }

    mutating func observe(_ now: Date) { latestSeen = max(latestSeen ?? now, now) }

    mutating func reconcile(purchased: Bool?, receiptDate: Date?) {
        if let purchased { purchasedPro = purchased }
        if let receiptDate {
            trialClaimedAt = min(receiptDate, trialClaimedAt ?? receiptDate)
            proStartedAt = min(receiptDate, trialStart)
        }
    }

    func canReview(at now: Date, careDays: Set<LocalDay>, free: Bool) -> Bool {
        !requestedReview && now.timeIntervalSince(firstOpen) >= 7 * 86400 && careDays.count >= 3 && hasPro(at: now, free: free)
    }
}
