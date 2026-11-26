import Foundation
import Observation
import StoreKit
import UIKit

@MainActor @Observable final class AppModel {
    var plants: [PlantRecord] = []
    var now = Date()
    var ready = false
    var busy = false
    var purchaseBusy = false
    var error: String?
    var undo: WaterUndo?
    var notice: String?
    var heldDue: [UUID]?
    var entitlement: Entitlement?
    var pro: Product?
    var trial: Product?
    var navigation: [UUID] = []
    var reviewReady = false
    var active = false
    var pendingURL: URL?
    private var store: PlantStore?
    private(set) var files: LocalFiles?
    private let reminders = Reminders()
    private let vault = TrialVault()
    private var statusGeneration = 0
    private var noticeTask: Task<Void, Never>?

    var today: LocalDay { LocalDay(now) }
    var activePlants: [PlantRecord] { plants.filter { $0.archivedAt == nil } }
    var archived: [PlantRecord] { plants.filter { $0.archivedAt != nil } }
    var dueCount: Int { activePlants.filter { $0.isDue(on: today) }.count }
    var hasPro: Bool { Launch.isFree || entitlement?.hasPro(at: now, free: false) == true }
    var canAdd: Bool { hasPro || activePlants.count < 3 }

    private func clock() -> Date {
        #if DEBUG
        if Launch.testing, Launch.arguments.contains("-fixtures") {
            return LocalDay(rawValue: 20261119).date(hour: 10)
        }
        #endif
        return Date()
    }

    func start() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        now = clock()
        let launchTime = now
        do {
            let root = try await Task.detached {
                let manager = FileManager.default
                var root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent(Launch.testing ? "PlantLog-UITests" : "PlantLog", isDirectory: true)
                if Launch.testing, Launch.arguments.contains("-reset"), manager.fileExists(atPath: root.path) {
                    try manager.removeItem(at: root)
                }
                try manager.createDirectory(at: root, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                return root
            }.value
            let opened = try await PlantStore.open(root: root)
            let local = LocalFiles(root: root)
            store = opened
            files = local
            #if DEBUG
            if Launch.testing, Launch.arguments.contains("-fixtures"), try await opened.snapshot().isEmpty {
                let fixtures = try await Self.fixtures(now: launchTime, files: local)
                try await opened.seed(fixtures)
            }
            #endif
            plants = try await opened.snapshot()
        } catch {
            self.error = L.t("本地相册打开失败，请重试。")
            return
        }
        do { entitlement = try await vault.load(at: launchTime) }
        catch { self.error = L.t("无法读取高级资格，基础功能仍可使用。") }
        ready = true
        await refreshClock()
    }

    func refreshClock(schedule: Bool = true) async {
        now = clock()
        if var value = entitlement, value.latestSeen == nil || now.timeIntervalSince(value.latestSeen ?? now) >= 60 || (value.latestSeen ?? .distantPast) < value.trialEnd && now >= value.trialEnd {
            value.observe(now)
            await saveEntitlement(value)
        }
        if schedule && ready { await reminders.reconcile(plants, now: now) }
    }

    private func saveEntitlement(_ value: Entitlement) async {
        entitlement = value
        do { try await vault.save(value) }
        catch { self.error = L.t("无法保存高级资格。") }
    }

    func watchPurchases() async {
        guard ready, !Launch.isFree, !Launch.testing else { return }
        async let initial: Void = refreshPurchases()
        for await result in StoreKit.Transaction.updates {
            guard case .verified(let transaction) = result,
                  [Purchases.proID, Purchases.trialID].contains(transaction.productID) else { continue }
            await refreshPurchases()
            await transaction.finish()
        }
        await initial
    }

    func refreshPurchases() async {
        guard !Launch.isFree, !Launch.testing else { return }
        statusGeneration += 1
        let generation = statusGeneration
        let status = await Purchases.status()
        guard generation == statusGeneration, var value = entitlement else { return }
        value.reconcile(purchased: status.purchased, receiptDate: status.receiptDate)
        if value != entitlement { await saveEntitlement(value) }
    }

    func disclose() async {
        guard var value = entitlement else { return }
        value.disclosedTrial = true
        await saveEntitlement(value)
    }

    func loadProducts() async {
        guard !Launch.isFree, !Launch.testing, !purchaseBusy else { return }
        purchaseBusy = true
        defer { purchaseBusy = false }
        do {
            let products = try await Product.products(for: [Purchases.proID, Purchases.trialID])
            pro = products.first { $0.id == Purchases.proID && $0.type == .nonConsumable }
            trial = products.first { $0.id == Purchases.trialID && $0.type == .nonConsumable && $0.price == 0 }
        } catch { self.error = L.t("暂时无法连接 App Store。") }
    }

    func purchase(_ product: Product) async {
        guard !purchaseBusy else { return }
        purchaseBusy = true
        defer { purchaseBusy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                statusGeneration += 1
                if var value = entitlement {
                    value.reconcile(purchased: transaction.productID == Purchases.proID ? true : nil,
                                    receiptDate: transaction.productID == Purchases.trialID ? transaction.originalPurchaseDate : nil)
                    await saveEntitlement(value)
                    await transaction.finish()
                } else { error = L.t("无法保存高级资格。") }
            case .pending: showNotice(L.t("购买等待批准。"))
            case .userCancelled: break
            default: error = L.t("无法验证购买。")
            }
        } catch { self.error = L.t("暂时无法连接 App Store。") }
    }

    func restore() async {
        guard !purchaseBusy else { return }
        if Launch.testing {
            if Launch.arguments.contains("-restore-pro"), var value = entitlement {
                value.reconcile(purchased: true, receiptDate: nil)
                await saveEntitlement(value)
            } else { showNotice(L.t("没有可恢复的买断或试用凭证。")) }
            return
        }
        purchaseBusy = true
        defer { purchaseBusy = false }
        do {
            try await AppStore.sync()
            await refreshPurchases()
            showNotice(entitlement?.purchasedPro == true || entitlement?.trialClaimedAt != nil
                       ? L.t("已恢复购买。") : L.t("没有可恢复的买断或试用凭证。"))
        } catch { self.error = L.t("恢复购买未完成，请重试。") }
    }

    @discardableResult func edit(_ edit: PlantEdit, id: UUID? = nil) async -> Bool {
        guard let store, !busy else { return false }
        busy = true
        defer { busy = false }
        await refreshClock(schedule: false)
        let before = heldDue ?? PlantRecord.dueFirst(activePlants, on: today)
        let authorize: Bool
        if case .reminder(let interval) = edit, interval != nil, let id {
            authorize = plants.first(where: { $0.id == id })?.interval == nil
        } else { authorize = false }
        let result: (WaterUndo?, [String])
        do { result = try await store.apply(edit, to: id, now: now, today: today, hasPro: hasPro) }
        catch StoreError.limit { return false }
        catch StoreError.staleUndo { clearNotice(); return false }
        catch { self.error = L.t("没有保存，请重试。"); return false }

        if let updated = try? await store.snapshot() { plants = updated }
        else { error = L.t("记录已保存，但未能刷新相册。") }
        if !result.1.isEmpty { await files?.remove(result.1) }
        if let token = result.0 { showNotice(L.t("已记浇水"), undo: token, hold: before) }
        else if case .undo = edit { showNotice(L.t("已撤销")) }
        else if case .postpone = edit { showNotice(L.t("明天再查盆土")) }
        else if let undo, undo.plant == id {
            switch edit {
            case .reminder, .log, .removeEvent, .delete, .archive: clearNotice()
            default: break
            }
        }
        if case .log = edit, !Launch.testing, var value = entitlement {
            value.coreReviewProgress = .recording(value.coreReviewProgress)
            await saveEntitlement(value)
            if error == nil { CoreReview.shared.record(value.coreReviewProgress) }
        }
        if case .seeMilestone = edit { return true }
        else {
            Task {
                if authorize { await reminders.authorize() }
                await reminders.reconcile(plants, now: clock())
            }
        }
        return true
    }

    func acceptPhoto(_ item: PickedPhoto, for id: UUID) async {
        guard let files else { return }
        do {
            let photo = try await files.importPhoto(item.url)
            if !(await edit(.photo(photo), id: id)) {
                await files.remove([photo.path])
                error = L.t("照片未保存，请重试。")
            }
        } catch { self.error = L.t("照片未保存，请重试。") }
    }

    func clearNotice() {
        noticeTask?.cancel()
        notice = nil
        undo = nil
        heldDue = nil
    }

    func showNotice(_ text: String, undo token: WaterUndo? = nil, hold: [UUID]? = nil) {
        clearNotice()
        notice = text
        undo = token
        heldDue = hold
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(token == nil ? 4 : 8)) } catch { return }
            self?.clearNotice()
        }
    }

    func requestSharedReview(_ request: () -> Void) async {
        guard reviewReady, active, var value = entitlement else { return }
        reviewReady = false
        let days = Set(plants.flatMap(\.events).filter { $0.kind != .photo }.map { $0.recordedOn ?? LocalDay($0.createdAt) })
        guard CoreReview.shared.attempt(ifEligible: { value.canReview(at: clock(), careDays: days, free: Launch.isFree) }, request) else { return }
        value.requestedReview = true
        await saveEntitlement(value)
    }

        #if DEBUG
    private static func fixtures(now: Date, files: LocalFiles) async throws -> [PlantRecord] {
        let today = LocalDay(now)
        var first = PlantRecord(name: L.t("龟背竹"), createdAt: now.addingTimeInterval(-100), interval: 7, reminderStart: today.adding(-20))
        for (asset, offset) in [("demo-before", -16), ("demo-after", -1)] {
            guard let url = Bundle.main.url(forResource: asset, withExtension: "jpg") else { throw StoreError.missing }
            let photo = try await files.importPhoto(url, discardInput: false)
            first.events.append(EventRecord(kind: .photo, day: today.adding(offset), createdAt: now.addingTimeInterval(Double(offset) * 86400), photo: photo))
        }
        first.events.append(EventRecord(kind: .repot, day: today.adding(-12), createdAt: now.addingTimeInterval(-12 * 86400)))
        first.events.append(EventRecord(kind: .water, day: today.adding(-7), createdAt: now.addingTimeInterval(-7 * 86400)))
        first.recordMilestone()
        var records = [first, PlantRecord(name: L.t("绿萝"), createdAt: now.addingTimeInterval(-80), interval: 3, reminderStart: today),
                       PlantRecord(name: L.t("虎尾兰"), createdAt: now.addingTimeInterval(-60))]
        if Launch.arguments.contains("-five") {
            records += [PlantRecord(name: L.t("吊兰"), createdAt: now.addingTimeInterval(-40)),
                        PlantRecord(name: L.t("橡皮树"), createdAt: now.addingTimeInterval(-20))]
        }
        return records
    }
    #endif
}
