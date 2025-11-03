import Foundation
import SwiftUI
import UIKit

enum CachedAsyncImagePhase {
    case empty
    case loading
    case success(UIImage)
    case failure(Error)

    var image: UIImage? {
        if case let .success(image) = self { return image }
        return nil
    }

    var error: Error? {
        if case let .failure(error) = self { return error }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

private enum RemoteImageError: Error {
    case decodingFailed
}

@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published private(set) var phase: CachedAsyncImagePhase = .empty

    private var currentURL: URL?

    func load(url: URL) async {
        if currentURL == url {
            if case .success = phase {
                return
            }
        }

        currentURL = url

        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(cached)
            return
        }

        phase = .loading

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            guard let image = UIImage(data: data) else {
                throw RemoteImageError.decodingFailed
            }

            ImageCache.shared.insert(image, for: url)

            if url == currentURL {
                phase = .success(image)
            }
        } catch {
            if url == currentURL {
                phase = .failure(error)
            }
        }
    }

    func reset() {
        phase = .empty
        currentURL = nil
    }
}

final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, UIImage>

    private init() {
        cache = NSCache()
        cache.countLimit = 200
        cache.totalCostLimit = 1024 * 1024 * 100 // ~100 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

struct CachedAsyncImage<Content: View>: View {
    private let url: URL
    private let content: (CachedAsyncImagePhase) -> Content

    @StateObject private var loader = CachedImageLoader()

    init(url: URL, @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(loader.phase)
            .task(id: url) {
                await loader.load(url: url)
            }
            .onDisappear {
                loader.reset()
            }
    }
}
