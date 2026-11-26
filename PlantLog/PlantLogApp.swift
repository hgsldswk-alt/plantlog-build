import Combine
import Foundation
import StoreKit
import SwiftUI
import UIKit
import UserNotifications

final class PlantDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let destination = CurrentValueSubject<UUID?, Never>(nil)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["plantID"] as? String
        if let raw, let id = UUID(uuidString: raw) { await MainActor.run { Self.destination.send(id) } }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

enum Panel: Identifiable {
    case add, rename(PlantRecord), log(PlantRecord, EventRecord?), reminder(PlantRecord)
    case gift(PlantRecord), receive(CareTransfer?), photo(EventRecord), about, paywall, disclosure
    var id: String {
        switch self {
        case .add: "add"
        case .rename: "rename"
        case .log: "log"
        case .reminder: "reminder"
        case .gift: "gift"
        case .receive: "receive"
        case .photo: "photo"
        case .about: "about"
        case .paywall: "paywall"
        case .disclosure: "disclosure"
        }
    }
}

@main @MainActor struct PlantLogApp: App {
    @UIApplicationDelegateAdaptor(PlantDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup { RootView(model: model).preferredColorScheme(.light) }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @State private var panel: Panel?
    @State private var nextPanel: Panel?
    @State private var pendingPlant: UUID?
    @State private var sharing: SharePayload?
    @State private var loadingShare = false
    @State private var comparisonDemo: SharePayload?

    var body: some View {
        NavigationStack(path: $model.navigation) {
            Group {
                if model.ready { HomeView(model: model, present: present) }
                else if model.busy { ProgressView(L.t("打开相册…")) }
                else { Button(L.t("重试")) { Task { await model.start() } }.buttonStyle(CareButton(prominent: true)).accessibilityIdentifier("retry-store") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { plantID in
                if let plant = model.plants.first(where: { $0.id == plantID }) {
                    TimelineView(plant: plant, model: model, present: present) { compare(plant) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { notice }
        }
        .tint(Palette.green)
        .foregroundStyle(Palette.ink)
        .sheet(item: $panel, onDismiss: afterPanel) { value in
            panelView(value)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $sharing) { payload in
            ActivitySheet(payload: payload) { completed in
                sharing = nil
                if let url = payload.temporary { Task { await model.files?.removeExport(url) } }
                if completed, payload.promptsReview { model.reviewReady = true }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $comparisonDemo) { payload in
            PanelFrame(L.t("生长对比")) {
                if let preview = payload.preview {
                    Image(uiImage: preview).resizable().scaledToFit().accessibilityLabel(L.t("生长对比"))
                        .accessibilityIdentifier("comparison-card")
                }
            }.onDisappear {
                if let url = payload.temporary { Task { await model.files?.removeExport(url) } }
            }
        }
        .alert(L.t("提示"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L.t("好"), role: .cancel) { model.error = nil }.accessibilityIdentifier("dismiss-error")
        } message: { Text(model.error ?? "") }
        .task { await model.start() }
        .onChange(of: model.ready, initial: true) { _, ready in if ready { didStart() } }
        .task(id: model.ready) { await model.watchPurchases() }
        .task(id: phase) {
            model.active = phase == .active
            guard model.active else { return }
            guard model.ready else { return }
            await model.refreshClock()
            await model.refreshPurchases()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await model.refreshClock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await model.refreshClock() }
        }
        .onReceive(PlantDelegate.destination.compactMap { $0 }) { plantID in
            pendingPlant = plantID
            openPendingPlant()
        }
        .onOpenURL { url in
            model.pendingURL = url
            if model.ready { openPendingFile() }
        }
        .reviewAfterCoreAction(when: reviewHome) { requestReview() }
        .task(id: model.reviewReady && reviewHome) {
            guard model.reviewReady, reviewHome else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, reviewHome else { return }
            await model.requestSharedReview { requestReview() }
        }
    }

    private var reviewHome: Bool {
        model.active && model.ready && model.navigation.isEmpty && !model.busy && !model.purchaseBusy
            && panel == nil && nextPanel == nil && sharing == nil && comparisonDemo == nil && !loadingShare
            && model.error == nil && model.notice == nil
    }

    @ViewBuilder private var notice: some View {
        if let message = model.notice {
            HStack {
                Text(message).font(.subheadline)
                Spacer()
                if let undo = model.undo {
                    Button(L.t("撤销")) { Task { await model.edit(.undo(undo), id: undo.plant) } }
                        .buttonStyle(CareButton()).accessibilityIdentifier("undo-water")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 5)
            .foregroundStyle(.white).background(Palette.green, in: .rect(cornerRadius: 15))
            .padding(.horizontal, 16).padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notice")
        }
    }

    func present(_ value: Panel) {
        let destination: Panel
        if case .add = value, !model.canAdd { destination = .paywall } else { destination = value }
        if case .disclosure? = panel { nextPanel = destination }
        else if panel != nil { nextPanel = destination; panel = nil }
        else { panel = destination }
    }

    private func afterPanel() {
        if let nextPanel { self.nextPanel = nil; panel = nextPanel }
    }

    private func didStart() {
        model.active = phase == .active
        if Launch.testing, Launch.arguments.contains("-paywall") { panel = .paywall; return }
        if !Launch.isFree, model.entitlement?.disclosedTrial == false { panel = .disclosure }
        openPendingPlant()
        openPendingFile()
        #if DEBUG
        if Launch.testing, let importText = ProcessInfo.processInfo.environment["PLANTCARE_TEST_IMPORT"] {
            Task {
                do {
                    guard let files = model.files else { return }
                    let url = try await files.export(data: Data(importText.utf8), name: "fixture.plantcare")
                    await readFile(url)
                    await files.removeExport(url)
                } catch { model.error = L.t("养护设置无效或不受支持。") }
            }
        }
        #endif
    }

    private func openPendingPlant() {
        guard model.ready, let plantID = pendingPlant else { return }
        pendingPlant = nil
        PlantDelegate.destination.send(nil)
        if model.plants.contains(where: { $0.id == plantID }) { model.navigation = [plantID] }
    }

    private func openPendingFile() {
        guard let url = model.pendingURL else { return }
        model.pendingURL = nil
        Task { await readFile(url) }
    }

    private func readFile(_ url: URL) async {
        do {
            guard url.isFileURL, url.pathExtension.lowercased() == "plantcare", let files = model.files else { throw StoreError.invalid }
            let care = try await files.readCare(url)
            present(.receive(care))
        } catch { model.error = L.t("养护设置无效或不受支持。") }
    }

    @ViewBuilder private func panelView(_ value: Panel) -> some View {
        switch value {
        case .add: NamePanel(model: model, done: { panel = nil }, paywall: { present(.paywall) })
        case .rename(let plant): NamePanel(model: model, plant: plant, done: { panel = nil }, paywall: { present(.paywall) })
        case .log(let plant, let event): LogPanel(plant: plant, event: event, model: model) { panel = nil }
        case .reminder(let plant): ReminderPanel(plant: plant, model: model) { panel = nil }
        case .gift(let plant): GiftPanel(plant: plant, model: model)
        case .receive(let transfer): ReceivePanel(model: model, transfer: transfer, readFile: readFile) {
            panel = nil
        } paywall: { present(.paywall) }
        case .photo(let event): PhotoPanel(event: event, model: model)
        case .about: AboutPanel()
        case .paywall: PaywallPanel(model: model) { panel = nil }
        case .disclosure: PaywallPanel(model: model, disclosure: true) { panel = nil }.interactiveDismissDisabled()
        }
    }

    private func compare(_ plant: PlantRecord) {
        guard !loadingShare, let files = model.files else { return }
        Task {
            loadingShare = true
            defer { loadingShare = false }
            await model.refreshClock(schedule: false)
            guard model.hasPro else { present(.paywall); return }
            do {
                let payload = try await CardExport.comparison(plant, files: files)
                #if DEBUG
                if Launch.testing, Launch.arguments.contains("-store-shots") { comparisonDemo = payload; return }
                #endif
                sharing = payload
            }
            catch { model.error = L.t("对比图未生成，原照片仍可单独分享。") }
        }
    }
}
