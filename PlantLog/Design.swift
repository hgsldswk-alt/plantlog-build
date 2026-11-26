import SwiftUI
import PhotosUI

enum Palette {
    static let paper = Color(red: 0.973, green: 0.973, blue: 0.949)
    static let card = Color(red: 0.992, green: 0.992, blue: 0.976)
    static let green = Color(red: 0.149, green: 0.298, blue: 0.231)
    static let ink = Color(red: 0.098, green: 0.184, blue: 0.149)
    static let muted = Color(red: 0.329, green: 0.388, blue: 0.357)
    static let line = Color(red: 0.859, green: 0.886, blue: 0.851)
    static let soft = Color(red: 0.910, green: 0.933, blue: 0.894)
}

struct CareButton: ButtonStyle {
    var prominent = false
    var fillsWidth = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .foregroundStyle(prominent ? Color.white : Palette.green)
            .background(prominent ? Palette.green : Palette.soft, in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
    }
}

extension View {
    func plantCard() -> some View {
        padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.line).allowsHitTesting(false))
    }
}

struct PhotoThumb: View {
    let photo: PhotoRecord?
    let files: LocalFiles?
    @State private var image: UIImage?

    var body: some View {
        Color.clear.overlay {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Palette.soft.overlay { Image(systemName: "leaf").foregroundStyle(Palette.green) } }
        }
        .clipped()
        .clipShape(.rect(cornerRadius: 11))
        .contentShape(.rect(cornerRadius: 11))
        .accessibilityHidden(true)
        .task(id: photo?.id) {
            image = nil
            guard let photo, let files else { return }
            let loaded = await files.image(photo)
            if !Task.isCancelled { image = loaded }
        }
    }
}

struct AddPhoto: View {
    let plant: PlantRecord
    let model: AppModel
    let fill: Bool
    @State private var selection: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            if loading { ProgressView() } else { Text(L.t("加照片")) }
        }
        .buttonStyle(CareButton(fillsWidth: fill))
        .accessibilityIdentifier("photo-\(plant.id.uuidString)")
        .disabled(loading || model.busy)
        .onChange(of: selection) { _, item in
            guard let item, !loading else { return }
            loading = true
            Task {
                defer { selection = nil; loading = false }
                do {
                    guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else { throw StoreError.invalid }
                    await model.acceptPhoto(picked, for: plant.id)
                } catch { model.error = L.t("照片未保存，请重试。") }
            }
        }
    }
}
