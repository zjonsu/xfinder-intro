import AppKit
import SwiftUI
import QuickLookThumbnailing

/// Async QuickLook thumbnails for the icon view (real previews for images/PDFs/etc., falling back
/// to the file-type icon when a file has no preview). Results are cached; NSCache is thread-safe.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    /// A best-effort thumbnail for `url` at roughly `size` points, or nil if none could be made.
    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = "\(Int(size)):\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// A thumbnail that loads asynchronously, showing the file-type icon until (and unless) a richer
/// QuickLook preview arrives.
struct ThumbnailView: View {
    let item: FileItem
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                SystemActions.swiftUIImage(for: item).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.url) {
            // Folders and bundles already have good system icons; skip the QuickLook round-trip.
            guard !item.isDirectory || item.isBundle else { return }
            image = await ThumbnailCache.shared.thumbnail(for: item.url, size: size)
        }
    }
}
