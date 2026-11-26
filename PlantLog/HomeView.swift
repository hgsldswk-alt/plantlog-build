import SwiftUI

struct HomeView: View {
    let model: AppModel
    let present: (Panel) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if model.activePlants.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L.t("从第一盆植物开始")).font(.title2.bold())
                        Text(L.t("记下养护和照片，按自己的节奏照顾植物。")).foregroundStyle(Palette.muted)
                        Button(L.t("添加植物")) { present(.add) }
                            .buttonStyle(CareButton(prominent: true)).accessibilityIdentifier("add-empty")
                    }.frame(maxWidth: .infinity, alignment: .leading).plantCard()
                } else {
                    summary
                    let due = model.heldDue ?? PlantRecord.dueFirst(model.activePlants, on: model.today)
                    let byID = Dictionary(uniqueKeysWithValues: model.activePlants.map { ($0.id, $0) })
                    section(L.t("待查"), plants: due.compactMap { byID[$0] }, featured: true)
                    section(L.t("其他植物"), plants: model.activePlants.filter { !due.contains($0.id) }, featured: false)
                }
                if !model.archived.isEmpty {
                    DisclosureGroup(L.t("已归档")) {
                        ForEach(model.archived) { plant in titleButton(plant) }
                    }.plantCard()
                }
            }.padding(.horizontal, 19).padding(.vertical, 8)
        }
        .background(Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plants-home")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.now.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.footnote.weight(.semibold)).foregroundStyle(Palette.muted)
            HStack(spacing: 5) {
                Text(L.t("我的植物")).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Menu {
                    Button { present(.receive(nil)) } label: { Label(L.t("导入养护"), systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("import-care")
                    if !Launch.isFree {
                        Button { Task { await model.restore() } } label: { Label(L.t("恢复购买"), systemImage: "arrow.clockwise") }
                            .accessibilityIdentifier("restore-home")
                    }
                    Button { present(.about) } label: { Label(L.t("关于与隐私"), systemImage: "info.circle") }
                        .accessibilityIdentifier("about")
                } label: {
                    Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel(L.t("更多")).accessibilityIdentifier("home-more")
                if !model.activePlants.isEmpty {
                    Button { present(.add) } label: { Image(systemName: "plus").frame(minWidth: 26) }
                        .buttonStyle(CareButton(prominent: true)).accessibilityLabel(L.t("添加植物")).accessibilityIdentifier("add-plant")
                }
            }
        }
    }

    private var summary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("今天查盆土")).font(.title3.bold())
                Text(L.t("先摸一摸，干了再考虑浇水。")).font(.footnote).foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 8)
            Text(model.dueCount.formatted(.number.precision(.integerLength(2...))))
                .font(.largeTitle.weight(.regular).monospacedDigit()).fontDesign(.serif)
                .accessibilityLabel(L.f("%lld 盆待查", model.dueCount)).accessibilityIdentifier("due-count")
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white).background(Palette.green, in: RoundedRectangle(cornerRadius: 20))
            .padding(.top, 7)
    }

    @ViewBuilder private func section(_ label: String, plants: [PlantRecord], featured: Bool) -> some View {
        if !plants.isEmpty {
            HStack {
                Text(label).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L.f("%lld 盆", plants.count)).font(.footnote).foregroundStyle(Palette.muted)
            }.padding(.top, 5)
            ForEach(plants) { plant in plantCard(plant, featured: featured) }
        }
    }

    private func titleButton(_ plant: PlantRecord) -> some View {
        Button { model.navigation.append(plant.id) } label: {
            HStack(spacing: 5) {
                Text(plant.name).font(.headline).multilineTextAlignment(.leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted).accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("plant-\(plant.id.uuidString)")
    }

    private func plantCard(_ plant: PlantRecord, featured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if featured {
                HStack(spacing: 12) {
                    PhotoThumb(photo: plant.cover, files: model.files).frame(width: 68, height: 86)
                    VStack(alignment: .leading, spacing: 0) {
                        titleButton(plant)
                        Text(plant.lastWater.map { L.f("上次浇水 · %@", $0.shortLabel) } ?? L.t("还没记过浇水"))
                            .font(.footnote).foregroundStyle(Palette.muted)
                        Text(status(plant)).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Palette.soft, in: Capsule()).padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { titleButton(plant); Spacer(minLength: 8); statusLabel(plant) }.fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) { titleButton(plant); statusLabel(plant) }
                }
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 6) { actions(plant, featured: featured) }
            } else {
                HStack(spacing: 6) { actions(plant, featured: featured) }
            }
            if plant.isDue(on: model.today) {
                Button(L.t("土还湿，明天再看")) { Task { await model.edit(.postpone, id: plant.id) } }
                    .buttonStyle(CareButton(fillsWidth: true)).accessibilityIdentifier("postpone-\(plant.id.uuidString)")
                    .disabled(model.busy)
            }
        }.plantCard()
    }

    private func statusLabel(_ plant: PlantRecord) -> some View {
        Text(status(plant)).font(.footnote).foregroundStyle(Palette.muted)
    }

    private func status(_ plant: PlantRecord) -> String {
        guard let day = plant.nextCheck else { return L.t("提醒未开启") }
        if day == model.today { return L.t("今天待查") }
        if day < model.today { return L.f("%@ 起待查", day.shortLabel) }
        return L.f("%@ 查土", day.shortLabel)
    }

    @ViewBuilder private func actions(_ plant: PlantRecord, featured: Bool) -> some View {
        Button(L.t("已浇水")) { Task { await model.edit(.water, id: plant.id) } }
            .buttonStyle(CareButton(prominent: featured, fillsWidth: true)).accessibilityIdentifier("water-\(plant.id.uuidString)")
            .disabled(model.busy)
        Button(L.t("补记")) { present(.log(plant, nil)) }.buttonStyle(CareButton(fillsWidth: true))
            .accessibilityIdentifier("log-\(plant.id.uuidString)")
        AddPhoto(plant: plant, model: model, fill: true)
    }
}
