import Foundation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct PanelFrame<Content: View>: View {
    let title: String
    let content: Content
    let closable: Bool
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, closable: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.closable = closable
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if closable {
                        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel(L.t("关闭")).accessibilityIdentifier("close-panel")
                    }
                }
                content
            }.frame(maxWidth: .infinity, alignment: .leading).padding(19).padding(.top, 6)
        }.background(Palette.paper.ignoresSafeArea()).foregroundStyle(Palette.ink).tint(Palette.green)
    }
}

struct NamePanel: View {
    let model: AppModel
    var plant: PlantRecord? = nil
    let done: () -> Void
    let paywall: () -> Void
    @State private var name = ""

    var body: some View {
        PanelFrame(plant == nil ? L.t("添加植物") : L.t("改名")) {
            TextField(L.t("植物昵称"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("plant-name")
            Text(L.t("昵称限 1–40 个字符。照片和提醒可以稍后添加。")).font(.footnote).foregroundStyle(Palette.muted)
            Button(plant == nil ? L.t("添加植物") : L.t("保存")) {
                Task {
                    if plant == nil {
                        await model.refreshClock(schedule: false)
                        guard model.canAdd else { paywall(); return }
                    }
                    let action: PlantEdit = plant == nil ? .add(name) : .rename(name)
                    if await model.edit(action, id: plant?.id) { done() }
                }
            }.buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("save-plant")
                .disabled((try? CareTransfer(name: name, interval: nil)) == nil || model.busy)
        }.onAppear { name = plant?.name ?? "" }
    }
}

struct LogPanel: View {
    let plant: PlantRecord
    let event: EventRecord?
    let model: AppModel
    let done: () -> Void
    @State private var kind = CareKind.water
    @State private var day = LocalDay(Date())
    @State private var choosingDate = false

    var body: some View {
        PanelFrame(event == nil ? L.t("补记养护") : L.t("编辑记录")) {
            Text(plant.name).foregroundStyle(Palette.muted)
            if event?.photo == nil {
                Text(L.t("做了什么")).font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack { kinds }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading) { kinds }
                }
            }
            Text(L.t("哪一天")).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { dates }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading) { dates }
            }
            if choosingDate {
                DatePicker(L.t("选日期"), selection: Binding(get: { day.date() }, set: { day = LocalDay($0) }),
                           in: ...model.today.date(hour: 23), displayedComponents: .date)
                    .datePickerStyle(.graphical).accessibilityIdentifier("log-date")
            } else if day != model.today && day != model.today.adding(-1) { Text(day.formatted).foregroundStyle(Palette.muted) }
            Button(L.t("保存记录")) {
                Task { if await model.edit(.log(kind, day, event?.id), id: plant.id) { done() } }
            }.buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("save-log").disabled(model.busy)
        }.onAppear { day = event?.day ?? model.today.adding(-1); kind = event?.kind ?? .water }
    }

    @ViewBuilder private var kinds: some View {
        ForEach([CareKind.water, .repot, .bloom], id: \.self) { value in
            Button(value.label) { kind = value }.buttonStyle(CareButton(prominent: kind == value))
                .accessibilityAddTraits(kind == value ? [.isSelected] : [])
                .accessibilityIdentifier("log-kind-\(value.rawValue)")
        }
    }

    @ViewBuilder private var dates: some View {
        Button(L.t("今天")) { day = model.today; choosingDate = false }
            .buttonStyle(CareButton(prominent: day == model.today && !choosingDate)).accessibilityIdentifier("log-today")
        Button(L.t("昨天")) { day = model.today.adding(-1); choosingDate = false }
            .buttonStyle(CareButton(prominent: day == model.today.adding(-1) && !choosingDate)).accessibilityIdentifier("log-yesterday")
        Button(L.t("选日期")) { choosingDate.toggle() }.buttonStyle(CareButton(prominent: choosingDate)).accessibilityIdentifier("log-custom-date")
    }
}

struct ReminderPanel: View {
    let plant: PlantRecord
    let model: AppModel
    let done: () -> Void
    @State private var interval = ""
    private var valid: Int? {
        let digits = interval.compactMap(\.wholeNumberValue)
        guard digits.count == interval.count, digits.allSatisfy({ (0...9).contains($0) }),
              let value = Int(digits.map(String.init).joined()), (1...365).contains(value) else { return nil }
        return value
    }

    var body: some View {
        PanelFrame(L.t("检查提醒")) {
            Text(plant.name).font(.headline)
            Text(L.t("只提醒检查盆土，不提醒一定要浇水。通知在当地时间上午 9 点发送；即使不开通知，待查仍会显示在首页。"))
                .foregroundStyle(Palette.muted)
            Text(L.t("查土间隔（天）")).font(.headline)
            TextField(L.t("输入 1–365 天"), text: $interval).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                .accessibilityIdentifier("reminder-interval")
            Button(L.t("保存提醒")) {
                guard let valid else { return }
                Task { if await model.edit(.reminder(valid), id: plant.id) { done() } }
            }.buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("save-reminder").disabled(valid == nil || model.busy)
            if plant.interval != nil {
                Button(L.t("关闭提醒")) {
                    Task { if await model.edit(.reminder(nil), id: plant.id) { done() } }
                }.buttonStyle(CareButton(fillsWidth: true)).accessibilityIdentifier("disable-reminder").disabled(model.busy)
            }
        }.onAppear { interval = (plant.interval ?? plant.suggestedInterval ?? 7).formatted(.number.grouping(.never)) }
    }
}

extension UTType {
    static let plantCare = UTType(exportedAs: "com.hgsldswk.plantlog.plantcare", conformingTo: .json)
}

struct ReceivePanel: View {
    let model: AppModel
    let transfer: CareTransfer?
    let readFile: (URL) async -> Void
    let done: () -> Void
    let paywall: () -> Void
    @State private var parsed: CareTransfer?
    @State private var text = ""
    @State private var invalid = false
    @State private var choosingFile = false

    var body: some View {
        PanelFrame(L.t("导入养护")) {
            if let care = parsed ?? transfer {
                Text(care.name).font(.title.bold()).accessibilityIdentifier("import-name")
                Text(care.interval.map { L.f("发送者的查土间隔：%lld 天", $0) } ?? L.t("还没设置查土间隔"))
                Text(L.t("会新建一盆，不覆盖原记录。提醒默认关闭，你可以稍后开启。"))
                    .foregroundStyle(Palette.muted)
                Button(L.t("添加植物")) {
                    Task {
                        await model.refreshClock(schedule: false)
                        guard model.canAdd else { paywall(); return }
                        if await model.edit(.add(care.name, suggestedInterval: care.interval)) { done() }
                    }
                }.buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("confirm-import").disabled(model.busy)
            } else {
                Text(L.t("粘贴收到的养护口令，或选择 .plantcare 文件。"))
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { parse(value) }
                }.accessibilityIdentifier("paste-care")
                TextField(L.t("养护口令"), text: $text, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("care-code")
                Button(L.t("预览口令")) { parse(text) }.buttonStyle(CareButton()).accessibilityIdentifier("preview-code")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L.t("选择文件")) { choosingFile = true }.buttonStyle(CareButton()).accessibilityIdentifier("import-file")
                if invalid { Text(L.t("养护设置无效或不受支持。")).foregroundStyle(.red).accessibilityIdentifier("invalid-code") }
            }
        }.fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plantCare]) { result in
            switch result {
            case .success(let url): Task { await readFile(url) }
            case .failure(let error) where (error as? CocoaError)?.code == .userCancelled: break
            case .failure: invalid = true
            }
        }
    }

    private func parse(_ text: String) {
        parsed = try? CareTransfer.parse(text)
        invalid = parsed == nil
    }
}

struct AboutPanel: View {
    var body: some View {
        PanelFrame(L.t("关于与隐私")) {
            Text(L.t("植物相册")).font(.title.bold())
            Text(L.t("养护和照片只存本机。没有账号、广告或统计。只有你主动分享时，内容才交给系统分享；购买和评分由 App Store 处理。"))
        }
    }
}

struct PaywallPanel: View {
    let model: AppModel
    var disclosure = false
    let done: () -> Void

    var body: some View {
        PanelFrame(disclosure ? L.t("关于 30 天高级体验") : L.t("一次买断高级版"), closable: !disclosure) {
            Text(disclosure ? L.t("首次打开起计 30 天，不订阅、不自动扣费。") : summary)
                .font(.headline).accessibilityIdentifier("paywall-heading")
            Text(L.t("到期后仍可照常养护已有植物；添加第 4 盆及以上或导出双图需要买断。"))
            if let value = model.entitlement {
                if value.purchasedPro { Text(L.t("已买断高级版")).accessibilityIdentifier("pro-owned") }
                else if model.hasPro { Text(L.f("高级体验截至 %@", value.trialEnd.formatted(.dateTime.year().month().day().hour().minute()))) }
            }
            if let product = model.pro, model.entitlement?.purchasedPro != true {
                Button(L.f("一次买断 · %@", product.displayPrice)) { Task { await model.purchase(product) } }
                    .buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("buy-pro").disabled(model.purchaseBusy)
            } else if model.entitlement?.purchasedPro != true {
                Text(L.t("价格以 App Store 当前显示为准。")).font(.footnote).foregroundStyle(Palette.muted)
            }
            if model.entitlement?.trialClaimedAt == nil, model.entitlement?.purchasedPro != true {
                if let trial = model.trial {
                    Button(L.t("领取免费试用凭证")) { Task { await model.purchase(trial) } }
                        .buttonStyle(CareButton(fillsWidth: true)).accessibilityIdentifier("claim-trial").disabled(model.purchaseBusy)
                }
                Text(L.t("免费凭证只用于补充恢复资格，不会重新计时。")).font(.footnote).foregroundStyle(Palette.muted)
            }
            Button(L.t("恢复购买")) { Task { await model.restore() } }
                .buttonStyle(CareButton(fillsWidth: true)).accessibilityIdentifier("restore-purchases").disabled(model.purchaseBusy)
            if let notice = model.notice { Text(notice).accessibilityIdentifier("purchase-notice") }
            if disclosure {
                Button(L.t("继续使用")) { Task { await model.disclose(); done() } }
                    .buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("accept-trial")
            } else if !Launch.testing, model.pro == nil {
                Button(L.t("重试加载价格")) { Task { await model.loadProducts() } }
                    .buttonStyle(CareButton()).accessibilityIdentifier("reload-products").disabled(model.purchaseBusy)
            }
        }.task { await model.loadProducts() }
    }

    private var summary: String {
        model.hasPro ? L.t("添加更多植物，导出最近两张照片的对比图。") : L.t("30 天高级体验已结束。你的植物、照片和提醒照常使用。")
    }
}
