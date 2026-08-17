import CoreGraphics
import SwiftUI

/// Decodes on a background queue and publishes as each one lands, so a sheet of
/// 261 frames fills in progressively instead of blocking the first paint.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    /// Project root, so decoded thumbnails land in its `.astrocat/thumbs`.
    var project = ""

    private var inFlight: Set<String> = []
    private var pending: [(String, String, Int)] = []
    private var running = 0
    /// Each decode reads a 17 MB frame, so a few at a time — unbounded
    /// concurrency starves the main thread and the whole UI stops responding.
    private let maxConcurrent = 3
    private let queue = DispatchQueue(label: "astrocat.thumbnails", qos: .utility)

    private func key(_ path: String, _ size: Int) -> String { "\(size)|\(path)" }

    func image(_ path: String, size: Int = 96) -> CGImage? {
        let k = key(path, size)
        if let img = images[k] { return img }
        guard !path.isEmpty, !inFlight.contains(k) else { return nil }
        inFlight.insert(k)
        pending.append((k, path, size))
        pump()
        return nil
    }

    private func pump() {
        while running < maxConcurrent, !pending.isEmpty {
            let (k, path, size) = pending.removeLast()
            let project = self.project
            running += 1
            queue.async { [weak self] in
                let decoded = Self.decode(path, size, project)
                Task { @MainActor in
                    guard let self else { return }
                    self.running -= 1
                    self.inFlight.remove(k)
                    if let decoded { self.images[k] = decoded }
                    self.pump()
                }
            }
        }
    }


    private nonisolated static func decode(_ path: String, _ size: Int, _ project: String)
        -> CGImage?
    {
        let handle = project.withCString { p in
            path.withCString { s in ac_thumbnail_cached(p, s, UInt32(size)) }
        }
        guard let handle else { return nil }
        defer { ac_thumb_free(handle) }

        let w = Int(ac_thumb_width(handle))
        let h = Int(ac_thumb_height(handle))
        guard w > 0, h > 0, let base = ac_thumb_pixels(handle) else { return nil }

        let bytes = Data(bytes: base, count: w * h * 4)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }

        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

struct Thumbnail: View {
    let path: String
    var size: Int = 96
    @ObservedObject var store: ThumbnailStore
    let placeholder: Color

    var body: some View {
        GeometryReader { geo in
            if let img = store.image(path, size: size) {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                placeholder
            }
        }
    }
}
