import Foundation
import CryptoKit

actor MediaCache {
    static let shared = MediaCache()

    private let memoryCache = NSCache<NSURL, NSData>()
    private let fileManager = FileManager.default
    private let directoryURL: URL

    private init() {
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 60 * 1024 * 1024 // ~60 MB in-memory budget

        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = cachesDirectory.appendingPathComponent("MediaCache", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        applyFileProtectionIfAvailable(to: directory)
        directoryURL = directory
    }

    private func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for url: URL) -> URL {
        directoryURL.appendingPathComponent(cacheKey(for: url))
    }

    func cachedData(for url: URL) -> Data? {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return Data(referencing: cached)
        }
        let path = fileURL(for: url)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: path, options: [.mappedIfSafe]) else {
            return nil
        }
        memoryCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }

    func store(_ data: Data, for url: URL) {
        memoryCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        let path = fileURL(for: url)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        applyFileProtectionIfAvailable(to: directoryURL)
        do {
            try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            applyFileProtectionIfAvailable(to: path)
        } catch {
            #if DEBUG
            print("MediaCache disk write failed for \(url):", error.localizedDescription)
            #endif
        }
    }

    private func applyFileProtectionIfAvailable(to url: URL) {
        #if os(iOS)
        do {
            try fileManager.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: url.path)
        } catch {
            #if DEBUG
            print("Failed to apply file protection to \(url.lastPathComponent):", error.localizedDescription)
            #endif
        }
        #endif
    }

    func data(for url: URL) async throws -> Data {
        if let cached = cachedData(for: url) {
            return cached
        }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        let (data, _) = try await URLSession.shared.data(for: request)
        store(data, for: url)
        return data
    }

    func prefetch(url: URL) async {
        if cachedData(for: url) != nil {
            return
        }
        do {
            _ = try await data(for: url)
        } catch {
            #if DEBUG
            print("MediaCache prefetch failed for \(url):", error.localizedDescription)
            #endif
        }
    }
}
