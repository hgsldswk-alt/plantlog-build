import Foundation
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: received.file, to: target)
                return Self(url: target)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }
}

actor LocalFiles {
    let root: URL

    init(root: URL) { self.root = root }

    func importPhoto(_ url: URL, discardInput: Bool = true) throws -> PhotoRecord {
        defer { if discardInput { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = dimensions[kCGImagePropertyPixelWidth] as? Int,
              let height = dimensions[kCGImagePropertyPixelHeight] as? Int,
              let thumb = Self.thumbnail(source, max: 480) else { throw StoreError.invalid }
        let orientation = dimensions[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let id = UUID()
        let ext = CGImageSourceGetType(source).flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "image"
        let path = "\(id.uuidString).\(ext)"
        let original = root.appendingPathComponent(path)
        let preview = thumbnailURL(path)
        do {
            try FileManager.default.copyItem(at: url, to: original)
            try Self.writeJPEG(thumb, to: preview)
        } catch {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: preview)
            throw error
        }
        return PhotoRecord(id: id, path: path, width: rotated ? height : width, height: rotated ? width : height)
    }

    private static func thumbnail(_ source: CGImageSource, max size: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func thumbnailURL(_ path: String) -> URL { root.appendingPathComponent(path + ".thumb.jpg") }

    func image(_ photo: PhotoRecord, size: Int? = nil) -> UIImage? {
        let url = size == nil ? thumbnailURL(photo.path) : root.appendingPathComponent(photo.path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = Self.thumbnail(source, max: size ?? 480) else { return nil }
        return UIImage(cgImage: image)
    }

    func exportPhoto(_ photo: PhotoRecord) throws -> URL {
        let url = root.appendingPathComponent(photo.path)
        guard photo.width > 0, photo.height > 0, photo.width <= 60_000_000 / photo.height,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = Self.thumbnail(source, max: max(photo.width, photo.height)) else { throw StoreError.invalid }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("plant-photo.jpg")
        do { try Self.writeJPEG(image, to: target) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return target
    }

    func remove(_ paths: [String]) {
        for path in paths {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
            try? FileManager.default.removeItem(at: thumbnailURL(path))
        }
    }

    func readCare(_ url: URL) throws -> CareTransfer {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<CareTransfer, Error> = .failure(StoreError.invalid)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { input in
            result = Result {
                guard try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw StoreError.invalid }
                let handle = try FileHandle(forReadingFrom: input)
                defer { try? handle.close() }
                return try CareTransfer.decode(handle.read(upToCount: CareTransfer.byteLimit + 1) ?? Data())
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    func export(data: Data, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return url
    }

    func removeExport(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw StoreError.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.invalid }
    }
}
