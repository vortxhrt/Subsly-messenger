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

final class DiskImageCache {
    static let shared = DiskImageCache()

    private let directory: URL
    private let ioQueue = DispatchQueue(label: "DiskImageCache.io", qos: .utility)

    private init() {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = cachesDirectory.appendingPathComponent("AvatarImageCache", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            #if DEBUG
            print("DiskImageCache directory creation failed: \(error)")
            #endif
        }
    }

    func cachedImage(for url: URL) -> UIImage? {
        let fileURL = self.fileURL(for: url)
        return ioQueue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return UIImage(data: data)
        }
    }

    func image(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let fileURL = self.fileURL(for: url)
        ioQueue.async {
            guard let data = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func store(_ data: Data, for url: URL) {
        let fileURL = self.fileURL(for: url)
        ioQueue.async {
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                #if DEBUG
                print("DiskImageCache store failed: \(error)")
                #endif
            }
        }
    }

    private func fileURL(for url: URL) -> URL {
        let encodedName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return directory.appendingPathComponent(encodedName).appendingPathExtension("imgcache")
    }
}

struct CachedAsyncImage<Content: View>: View {
    private let url: URL
    private let content: (CachedAsyncImagePhase) -> Content

    @State private var phase: CachedAsyncImagePhase
    @State private var activeTask: URLSessionDataTask?
    @State private var currentURL: URL?

    init(url: URL, @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content) {
        self.url = url
        self.content = content

        if let cached = ImageCache.shared.image(for: url) {
            _phase = State(initialValue: .success(cached))
        } else if let diskImage = DiskImageCache.shared.cachedImage(for: url) {
            ImageCache.shared.insert(diskImage, for: url)
            _phase = State(initialValue: .success(diskImage))
        } else {
            _phase = State(initialValue: .empty)
        }

        _activeTask = State(initialValue: nil)
        _currentURL = State(initialValue: nil)
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
            beginNetworkLoad(for: url)
            return
        }

        phase = .loading

        DiskImageCache.shared.image(for: url) { image in
            guard self.currentURL == url else { return }
            if let image {
                ImageCache.shared.insert(image, for: url)
                self.phase = .success(image)
            }
        }

        beginNetworkLoad(for: url)
    }

    private func beginNetworkLoad(for url: URL) {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 60)
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
            DiskImageCache.shared.store(data, for: url)

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
            guard self.currentURL == url else { return }
            if case .success = self.phase {
                return
            }
            self.phase = .failure(error)
            self.activeTask = nil
        }
    }

    private func cancelLoad() {
        activeTask?.cancel()
        activeTask = nil
        currentURL = nil
    }
}
