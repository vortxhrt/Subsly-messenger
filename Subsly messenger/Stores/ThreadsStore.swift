import Foundation
import Combine
import SwiftUI
import FirebaseFirestore

@MainActor
final class ThreadsStore: ObservableObject {
    static let shared = ThreadsStore()

    @Published private(set) var threads: [ThreadModel] = []
    @Published private(set) var pinnedThreads: [ThreadModel] = []
    @Published private(set) var unpinnedThreads: [ThreadModel] = []

    private let defaults = UserDefaults.standard
    private let pinnedDefaultsKey = "ThreadsStore.pinnedThreadIDs"
    private let hiddenDefaultsKey = "ThreadsStore.hiddenThreadCutoffs"
    private let maxPinnedCount = 5

    private var pinnedThreadIDs: [String]
    private var hiddenThreadCutoffs: [String: Date]
    private var listener: ListenerRegistration?
    private var allThreads: [ThreadModel] = [] {
        didSet { applyThreadOrdering() }
    }

    private init() {
        let storedPinned = defaults.stringArray(forKey: pinnedDefaultsKey) ?? []
        if storedPinned.count > maxPinnedCount {
            pinnedThreadIDs = Array(storedPinned.prefix(maxPinnedCount))
        } else {
            pinnedThreadIDs = storedPinned
        }

        if let rawHidden = defaults.dictionary(forKey: hiddenDefaultsKey) as? [String: TimeInterval] {
            hiddenThreadCutoffs = rawHidden.reduce(into: [:]) { partialResult, element in
                partialResult[element.key] = Date(timeIntervalSince1970: element.value)
            }
        } else {
            hiddenThreadCutoffs = [:]
        }
    }

    func start(uid: String) {
        stop()
        listener = ChatService.shared.listenThreads(for: uid) { [weak self] models in
            Task { @MainActor in self?.handleIncoming(models) }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        allThreads = []
        threads = []
        pinnedThreads = []
        unpinnedThreads = []
    }

    func isPinned(_ thread: ThreadModel) -> Bool {
        guard let id = thread.id else { return false }
        return pinnedThreadIDs.contains(id)
    }

    func canPin(_ thread: ThreadModel) -> Bool {
        guard let id = thread.id else { return false }
        return isPinned(thread) || pinnedThreadIDs.count < maxPinnedCount
    }

    func togglePin(_ thread: ThreadModel) {
        guard let id = thread.id else { return }
        if let existingIndex = pinnedThreadIDs.firstIndex(of: id) {
            pinnedThreadIDs.remove(at: existingIndex)
            savePinnedThreadIDs()
            applyThreadOrdering()
            return
        }

        guard pinnedThreadIDs.count < maxPinnedCount else { return }
        pinnedThreadIDs.append(id)
        savePinnedThreadIDs()
        applyThreadOrdering()
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        pinnedThreadIDs.move(fromOffsets: source, toOffset: destination)
        savePinnedThreadIDs()
        applyThreadOrdering()
    }

    func softDelete(_ thread: ThreadModel) {
        guard let id = thread.id else { return }
        hiddenThreadCutoffs[id] = Date()
        saveHiddenThreadCutoffs()
        if let existingIndex = pinnedThreadIDs.firstIndex(of: id) {
            pinnedThreadIDs.remove(at: existingIndex)
            savePinnedThreadIDs()
        }
        applyThreadOrdering()
    }

    func deletionCutoff(for threadId: String) -> Date? {
        hiddenThreadCutoffs[threadId]
    }

    private func handleIncoming(_ models: [ThreadModel]) {
        allThreads = models
    }

    private func applyThreadOrdering() {
        var visibleThreads: [ThreadModel] = []

        for thread in allThreads {
            guard let id = thread.id else { continue }

            if let cutoff = hiddenThreadCutoffs[id] {
                guard let updated = thread.updatedAt, updated > cutoff else { continue }
            }

            visibleThreads.append(thread)
        }

        let existingIDs = Set(allThreads.compactMap { $0.id })
        let prunedHidden = hiddenThreadCutoffs.filter { existingIDs.contains($0.key) }
        if prunedHidden != hiddenThreadCutoffs {
            hiddenThreadCutoffs = prunedHidden
            saveHiddenThreadCutoffs()
        }

        var sanitizedPinnedIDs = pinnedThreadIDs.filter { existingIDs.contains($0) }
        if sanitizedPinnedIDs.count > maxPinnedCount {
            sanitizedPinnedIDs = Array(sanitizedPinnedIDs.prefix(maxPinnedCount))
        }
        if sanitizedPinnedIDs != pinnedThreadIDs {
            pinnedThreadIDs = sanitizedPinnedIDs
            savePinnedThreadIDs()
        }

        var pinned: [ThreadModel] = []
        var unpinned: [ThreadModel] = []
        let pinnedOrder = Dictionary(uniqueKeysWithValues: sanitizedPinnedIDs.enumerated().map { ($1, $0) })

        for thread in visibleThreads {
            guard let id = thread.id else { continue }
            if let _ = pinnedOrder[id] {
                pinned.append(thread)
            } else {
                unpinned.append(thread)
            }
        }

        pinned.sort { lhs, rhs in
            guard
                let lhsId = lhs.id,
                let rhsId = rhs.id,
                let lhsIndex = pinnedOrder[lhsId],
                let rhsIndex = pinnedOrder[rhsId]
            else { return false }
            return lhsIndex < rhsIndex
        }

        unpinned.sort { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? .distantPast
            return lhsDate > rhsDate
        }

        pinnedThreads = pinned
        unpinnedThreads = unpinned
        threads = pinned + unpinned
    }

    private func savePinnedThreadIDs() {
        defaults.set(pinnedThreadIDs, forKey: pinnedDefaultsKey)
    }

    private func saveHiddenThreadCutoffs() {
        let raw = hiddenThreadCutoffs.mapValues { $0.timeIntervalSince1970 }
        defaults.set(raw, forKey: hiddenDefaultsKey)
    }
}
