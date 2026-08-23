import SwiftUI

/// Loads and caches website favicons (via Google's favicon service), by host.
enum FaviconStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func host(_ urlString: String) -> String? {
        let s = urlString.contains("://") ? urlString : "https://\(urlString)"
        return URL(string: s)?.host?.replacingOccurrences(of: "www.", with: "")
    }
    static func cached(_ host: String) -> NSImage? {
        NSImage(contentsOf: dir.appendingPathComponent("\(host).png"))
    }
    static func download(_ host: String) async -> NSImage? {
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64"),
              let data = try? await URLSession.shared.data(from: url).0, data.count > 100 else { return nil }
        try? data.write(to: dir.appendingPathComponent("\(host).png"), options: .atomic)
        return NSImage(data: data)
    }
}

/// Favicon for a URL, with a symbol fallback while loading / if unavailable.
struct FaviconView: View {
    let urlString: String
    var fallbackSymbol: String = "link"
    var size: CGFloat = 18
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: fallbackSymbol).frame(width: size, height: size).foregroundStyle(.tint)
            }
        }
        .task(id: urlString) {
            guard let host = FaviconStore.host(urlString) else { return }
            if let c = FaviconStore.cached(host) { image = c; return }
            image = await FaviconStore.download(host)
        }
    }
}
