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

    private var currentUserID: String?
    private var pinnedThreadIDs: [String] = []
    private var hiddenThreadCutoffs: [String: Date] = [:]
    private var listener: ListenerRegistration?
    private var hasLoadedInitialSnapshot = false
    private var allThreads: [ThreadModel] = [] {
        didSet { applyThreadOrdering() }
    }

    private init() {}

    func start(uid: String) {
        if currentUserID == uid, listener != nil {
            return
        }

        listener?.remove()
        listener = nil

        hasLoadedInitialSnapshot = false

        if currentUserID != uid {
            currentUserID = uid
            loadPreferences(for: uid)
        }

        allThreads = []
        pinnedThreads = []
        unpinnedThreads = []
        threads = []

        listener = ChatService.shared.listenThreads(for: uid) { [weak self] models in
            Task { @MainActor in
                guard let self else { return }
                self.hasLoadedInitialSnapshot = true
                self.handleIncoming(models)
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        hasLoadedInitialSnapshot = false
        allThreads = []
        threads = []
        pinnedThreads = []
        unpinnedThreads = []
        currentUserID = nil
        pinnedThreadIDs = []
        hiddenThreadCutoffs = [:]
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
        guard hasLoadedInitialSnapshot || !allThreads.isEmpty else {
            pinnedThreads = []
            unpinnedThreads = []
            threads = []
            return
        }

        var visibleThreads: [ThreadModel] = []

        for thread in allThreads {
            guard let id = thread.id else { continue }

            if let cutoff = hiddenThreadCutoffs[id] {
                guard let updated = thread.updatedAt, updated > cutoff else { continue }
            }

            visibleThreads.append(thread)
        }

        let existingIDs = Set(allThreads.compactMap { $0.id })
        if existingIDs.isEmpty {
            if hasLoadedInitialSnapshot {
                if !pinnedThreadIDs.isEmpty {
                    pinnedThreadIDs = []
                    savePinnedThreadIDs()
                }
                if !hiddenThreadCutoffs.isEmpty {
                    hiddenThreadCutoffs = [:]
                    saveHiddenThreadCutoffs()
                }
            }
            pinnedThreads = []
            unpinnedThreads = []
            threads = []
            return
        }
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
        guard let uid = currentUserID else { return }
        defaults.set(pinnedThreadIDs, forKey: pinnedDefaultsKey(for: uid))
    }

    private func saveHiddenThreadCutoffs() {
        guard let uid = currentUserID else { return }
        let raw = hiddenThreadCutoffs.mapValues { $0.timeIntervalSince1970 }
        defaults.set(raw, forKey: hiddenDefaultsKey(for: uid))
    }

    private func loadPreferences(for uid: String) {
        if let storedPinned = defaults.stringArray(forKey: pinnedDefaultsKey(for: uid)) {
            pinnedThreadIDs = Array(storedPinned.prefix(maxPinnedCount))
        } else if let legacyPinned = defaults.stringArray(forKey: pinnedDefaultsKey) {
            let truncated = Array(legacyPinned.prefix(maxPinnedCount))
            pinnedThreadIDs = truncated
            defaults.set(truncated, forKey: pinnedDefaultsKey(for: uid))
            defaults.removeObject(forKey: pinnedDefaultsKey)
        } else {
            pinnedThreadIDs = []
        }

        if let rawHidden = defaults.dictionary(forKey: hiddenDefaultsKey(for: uid)) as? [String: TimeInterval] {
            hiddenThreadCutoffs = rawHidden.reduce(into: [:]) { partialResult, element in
                partialResult[element.key] = Date(timeIntervalSince1970: element.value)
            }
        } else if let legacyHidden = defaults.dictionary(forKey: hiddenDefaultsKey) as? [String: TimeInterval] {
            hiddenThreadCutoffs = legacyHidden.reduce(into: [:]) { partialResult, element in
                partialResult[element.key] = Date(timeIntervalSince1970: element.value)
            }
            defaults.set(legacyHidden, forKey: hiddenDefaultsKey(for: uid))
            defaults.removeObject(forKey: hiddenDefaultsKey)
        } else {
            hiddenThreadCutoffs = [:]
        }
    }

    private func pinnedDefaultsKey(for uid: String) -> String {
        "\(pinnedDefaultsKey).\(uid)"
    }

    private func hiddenDefaultsKey(for uid: String) -> String {
        "\(hiddenDefaultsKey).\(uid)"
    }
}
