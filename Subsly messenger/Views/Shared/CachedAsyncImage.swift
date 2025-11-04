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
    case badStatusCode
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

    @State private var phase: CachedAsyncImagePhase = .empty
    @State private var activeTask: URLSessionDataTask?
    @State private var currentURL: URL?

    init(url: URL, @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            .onAppear {
                load(for: url, forceReload: false)
            }
            .onChange(of: url) { newValue in
                load(for: newValue, forceReload: true)
            }
            .onDisappear {
                cancelLoad()
                phase = .empty
            }
    }

    private func load(for url: URL, forceReload: Bool) {
        if !forceReload, currentURL == url {
            switch phase {
            case .success, .loading:
                return
            default:
                break
            }
        }

        cancelLoad()
        currentURL = url

        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(cached)
            return
        }

        phase = .loading

        let request = URLRequest(url: url)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    return
                }

                self.publishFailure(error, for: url)
                return
            }

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                self.publishFailure(RemoteImageError.badStatusCode, for: url)
                return
            }

            guard let data = data,
                  let image = UIImage(data: data) else {
                self.publishFailure(RemoteImageError.decodingFailed, for: url)
                return
            }

            ImageCache.shared.insert(image, for: url)

            DispatchQueue.main.async {
                if self.currentURL == url {
                    self.phase = .success(image)
                    self.activeTask = nil
                }
            }
        }

        activeTask = task
        task.resume()
    }

    private func publishFailure(_ error: Error, for url: URL) {
        DispatchQueue.main.async {
            if self.currentURL == url {
                self.phase = .failure(error)
                self.activeTask = nil
            }
        }
    }

    private func cancelLoad() {
        activeTask?.cancel()
        activeTask = nil
        currentURL = nil
    }
}
