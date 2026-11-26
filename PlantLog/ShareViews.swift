import LinkPresentation
import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
    var text: String? = nil
    var preview: UIImage? = nil
    var temporary: URL? = nil
    var promptsReview = false
}

private final class SharedFile: NSObject, UIActivityItemSource {
    let payload: SharePayload
    init(_ payload: SharePayload) { self.payload = payload }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { payload.url }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { payload.url }
    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        guard let preview = payload.preview else { return nil }
        let metadata = LPLinkMetadata()
        metadata.title = L.t("植物相册")
        metadata.imageProvider = NSItemProvider(object: preview)
        return metadata
    }
}

private final class CopyCaption: UIActivity {
    static let identifier = UIActivity.ActivityType("com.hgsldswk.plantlog.copy-caption")
    private let caption: String
    init(_ caption: String) { self.caption = caption }
    override var activityTitle: String? { L.t("复制分享文字") }
    override var activityImage: UIImage? { UIImage(systemName: "doc.on.doc") }
    override var activityType: UIActivity.ActivityType? { Self.identifier }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { !caption.isEmpty }
    override func perform() {
        UIPasteboard.general.string = caption
        activityDidFinish(true)
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let payload: SharePayload
    let complete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [SharedFile(payload)]
        if let text = payload.text { items.append(text) }
        let custom = payload.text.map { [CopyCaption($0)] } ?? []
        let controller = UIActivityViewController(activityItems: items, applicationActivities: custom)
        controller.completionWithItemsHandler = { activity, completed, _, error in
            complete(completed && error == nil && activity != CopyCaption.identifier)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareCard: View {
    let name: String
    let title: String
    let photos: [UIImage]
    let dates: [String]
    let gift: String?
    let qr: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(name).font(.system(size: 29, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
            if photos.count == 2 {
                HStack(alignment: .top, spacing: 10) {
                    photo(photos[0], date: dates[0])
                    photo(photos[1], date: dates[1])
                }
            } else if let gift {
                Spacer(minLength: 0)
                Image(systemName: "leaf").font(.system(size: 50)).foregroundStyle(Palette.green)
                Text(gift).font(.system(size: 18, weight: .medium)).lineLimit(6).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("植物相册")).font(.system(size: 13, weight: .semibold))
                    Text(Launch.testing ? L.t("示例二维码 · 非下载地址") : L.t("#植物养护记录 #阳台种植"))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if let qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().padding(4)
                        .frame(width: 54, height: 54).background(.white)
                } else if Launch.testing {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line).frame(width: 54, height: 54)
                }
            }
        }
        .padding(18).frame(width: 360, height: 480)
        .foregroundStyle(Palette.ink).background(Palette.paper)
        .environment(\.dynamicTypeSize, .medium)
    }

    private func photo(_ image: UIImage, date: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear.frame(height: 234).overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipped().clipShape(.rect(cornerRadius: 9))
            Text(date).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.frame(width: 157)
    }
}

@MainActor enum CardExport {
    static func giftText(_ care: CareTransfer) -> String {
        if let interval = care.interval { return L.f("每隔 %lld 天看看盆土，是否浇水由你判断。", interval) }
        return L.t("还没设置查土间隔")
    }

    static func comparison(_ plant: PlantRecord, files: LocalFiles) async throws -> SharePayload {
        let events = plant.comparison
        guard events.count == 2, let before = events[0].photo, let after = events[1].photo else { throw StoreError.invalid }
        async let left = files.image(before, size: 1440)
        async let right = files.image(after, size: 1440)
        guard let first = await left, let second = await right else { throw StoreError.invalid }
        let dates = events.map { $0.day.formatted }
        let title = events.map(\.id) == plant.milestone ? L.t("第一次生长对比") : L.t("生长对比")
        let qr = await qrImage()
        let card = ShareCard(name: plant.name, title: title, photos: [first, second], dates: dates, gift: nil, qr: qr)
        let text = L.f("同一盆%@：%@ 至 %@。", plant.name, dates[0], dates[1]) + "\n" + L.t("#植物养护记录 #阳台种植")
        return try await render(card, files: files, name: "plant-growth.png", text: text)
    }

    static func gift(_ care: CareTransfer, files: LocalFiles) async throws -> SharePayload {
        let qr = await qrImage()
        let card = ShareCard(name: care.name, title: L.t("赠养卡"), photos: [], dates: [], gift: giftText(care), qr: qr)
        let text = L.t("这是这盆的查土设置") + "\n" + (try care.code()) + "\n" + L.t("#植物养护记录 #阳台种植")
        return try await render(card, files: files, name: "plant-gift.png", text: text)
    }

    private static func qrImage() async -> UIImage? {
        let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String
        let example = Launch.testing && Launch.arguments.contains("-fixtures")
        guard let url = CardQR.url(storeID: id, example: example) else { return nil }
        return await Task.detached { CardQR.image(url).map { UIImage(cgImage: $0) } }.value
    }

    private static func render(_ card: ShareCard, files: LocalFiles, name: String, text: String) async throws -> SharePayload {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let cgImage = image.cgImage, cgImage.width == 1080, cgImage.height == 1440 else { throw StoreError.invalid }
        guard let data = await Task.detached(operation: { UIImage(cgImage: cgImage).pngData() }).value else { throw StoreError.invalid }
        let url = try await files.export(data: data, name: name)
        return SharePayload(url: url, text: text, preview: image, temporary: url, promptsReview: true)
    }
}

struct GiftPanel: View {
    let plant: PlantRecord
    let model: AppModel
    @State private var payload: SharePayload?
    @State private var copied = false
    @State private var working = false
    @State private var failure = false

    var body: some View {
        PanelFrame(L.t("赠养卡")) {
            if let care = try? CareTransfer(name: plant.name, interval: plant.interval) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "leaf").font(.largeTitle).accessibilityHidden(true)
                    Text(L.f("送你一盆%@", care.name)).font(.largeTitle.bold())
                    Text(CardExport.giftText(care)).font(.title3)
                    Text(L.t("只包含昵称和查土间隔，不包含照片或养护历史。"))
                        .font(.footnote).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).plantCard()
                Button(L.t("分享赠养卡")) { send(care, asFile: false) }
                    .buttonStyle(CareButton(prominent: true, fillsWidth: true)).accessibilityIdentifier("share-gift").disabled(working)
                Button(L.t("发设置文件")) { send(care, asFile: true) }
                    .buttonStyle(CareButton(fillsWidth: true)).accessibilityIdentifier("share-care-file").disabled(working)
                Button(copied ? L.t("口令已复制") : L.t("复制养护口令")) {
                    if let code = try? care.code() { UIPasteboard.general.string = code; copied = true }
                }.buttonStyle(CareButton(fillsWidth: true)).accessibilityIdentifier("copy-care")
                if failure { Text(L.t("分享未完成，请重试。")).foregroundStyle(.red) }
            }
        }.sheet(item: $payload) { item in
            ActivitySheet(payload: item) { completed in
                payload = nil
                if let url = item.temporary { Task { await model.files?.removeExport(url) } }
                if completed, item.promptsReview { model.reviewReady = true }
            }.interactiveDismissDisabled()
        }
    }

    private func send(_ care: CareTransfer, asFile: Bool) {
        guard !working, let files = model.files else { return }
        working = true
        failure = false
        Task {
            defer { working = false }
            do {
                if asFile {
                    let url = try await files.export(data: care.data(), name: "settings.plantcare")
                    payload = SharePayload(url: url, temporary: url)
                } else { payload = try await CardExport.gift(care, files: files) }
            } catch { failure = true }
        }
    }
}

struct PhotoPanel: View {
    let event: EventRecord
    let model: AppModel
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var payload: SharePayload?
    @State private var exporting = false
    @State private var failure = false
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        PanelFrame(event.day.formatted) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().scaleEffect(max(1, min(4, zoom * magnification)))
                    .clipped().accessibilityLabel(L.t("照片"))
                    .gesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { zoom = max(1, min(4, zoom * $0.magnification)) })
            }
            else if loaded { Text(L.t("无法读取照片。")) }
            else { ProgressView() }
            if let photo = event.photo, image != nil {
                Button { share(photo) } label: { Label(L.t("分享原照片"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(CareButton()).accessibilityIdentifier("share-original-photo").disabled(exporting)
            }
            if failure { Text(L.t("分享未完成，请重试。")).foregroundStyle(.red) }
        }.task {
            if let photo = event.photo, let files = model.files {
                image = await files.image(photo, size: 2560)
            }
            loaded = true
        }
        .sheet(item: $payload) { item in
            ActivitySheet(payload: item) { _ in
                payload = nil
                if let url = item.temporary { Task { await model.files?.removeExport(url) } }
            }.interactiveDismissDisabled()
        }
    }

    private func share(_ photo: PhotoRecord) {
        guard !exporting, let files = model.files else { return }
        exporting = true
        failure = false
        Task {
            defer { exporting = false }
            do {
                let url = try await files.exportPhoto(photo)
                payload = SharePayload(url: url, preview: image, temporary: url)
            } catch { failure = true }
        }
    }
}
