import SwiftUI

struct TimelineView: View {
    let plant: PlantRecord
    let model: AppModel
    let present: (Panel) -> Void
    let compare: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var showingMilestone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(plant.name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier("timeline-title")
                    Text(plant.lastWater.map { L.f("上次浇水 · %@", $0.shortLabel) } ?? L.t("还没记过浇水"))
                    Text(plant.nextCheck.map { L.f("下次查土 · %@", $0.shortLabel) } ?? (plant.archivedAt == nil ? L.t("提醒未开启") : L.t("已归档")))
                }.foregroundStyle(Palette.green).frame(maxWidth: .infinity, alignment: .leading).plantCard()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { actions }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) { actions }
                }
                if showingMilestone || (plant.milestone != nil && !plant.milestoneSeen) {
                    Label(L.t("这盆有两张照片了"), systemImage: "sparkles")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Palette.green)
                        .accessibilityIdentifier("first-comparison")
                }
                if plant.comparison.count == 2 {
                    Button(action: compare) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(L.t("分享生长对比"), systemImage: "square.and.arrow.up")
                            Text(L.f("%@ 至 %@", plant.comparison[0].day.formatted, plant.comparison[1].day.formatted))
                                .font(.footnote)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }.buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("share-comparison")
                }
                Text(L.t("养护时间轴")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if plant.events.isEmpty { Text(L.t("还没有养护记录。")).foregroundStyle(Palette.muted) }
                LazyVStack(spacing: 8) { ForEach(plant.timeline) { row($0) } }
            }.padding(19)
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: plant.milestone != nil && !plant.milestoneSeen && !model.busy) {
            guard plant.milestone != nil, !plant.milestoneSeen, !model.busy else { return }
            showingMilestone = true
            Task { await model.edit(.seeMilestone, id: plant.id) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L.t("改名")) { present(.rename(plant)) }.accessibilityIdentifier("rename-plant")
                    Button(plant.archivedAt == nil ? L.t("归档") : L.t("取消归档")) {
                        if plant.archivedAt != nil, !model.canAdd { present(.paywall); return }
                        Task { await model.edit(.archive(plant.archivedAt == nil), id: plant.id) }
                    }.accessibilityIdentifier("archive-plant")
                    Button(L.t("删除植物"), role: .destructive) { deleting = true }.accessibilityIdentifier("delete-plant")
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(L.t("更多")).accessibilityIdentifier("timeline-more")
            }
        }
        .confirmationDialog(L.t("删除植物和它的全部记录？"), isPresented: $deleting, titleVisibility: .visible) {
            Button(L.t("删除植物"), role: .destructive) {
                Task { if await model.edit(.delete, id: plant.id) { dismiss() } }
            }.accessibilityIdentifier("confirm-delete-plant")
        }
    }

    @ViewBuilder private var actions: some View {
        Button(L.t("检查提醒")) { present(.reminder(plant)) }.buttonStyle(CareButton()).accessibilityIdentifier("edit-reminder")
        Button(L.t("赠养卡")) { present(.gift(plant)) }.buttonStyle(CareButton()).accessibilityIdentifier("gift-care")
        Button(L.t("补记")) { present(.log(plant, nil)) }.buttonStyle(CareButton()).accessibilityIdentifier("timeline-log")
        AddPhoto(plant: plant, model: model, fill: false)
    }

    private func row(_ event: EventRecord) -> some View {
        HStack(spacing: 10) {
            if let photo = event.photo {
                Button { present(.photo(event)) } label: {
                    PhotoThumb(photo: photo, files: model.files).frame(width: 67, height: 78)
                }.buttonStyle(.plain).accessibilityLabel(L.f("查看 %@ 的照片", event.day.formatted))
                    .accessibilityIdentifier("view-photo-\(event.id.uuidString)")
            } else {
                Image(systemName: event.kind.icon).frame(width: 34, height: 34).background(Palette.soft, in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.label).font(.headline)
                Text(event.day.formatted).font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Menu {
                Button(L.t("编辑记录")) { present(.log(plant, event)) }.accessibilityIdentifier("edit-event")
                Button(L.t("删除记录"), role: .destructive) {
                    Task { await model.edit(.removeEvent(event.id), id: plant.id) }
                }.accessibilityIdentifier("delete-event")
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(L.t("记录选项")).accessibilityIdentifier("event-menu-\(event.id.uuidString)")
        }.plantCard().accessibilityIdentifier("event-\(event.kind.rawValue)")
    }
}
