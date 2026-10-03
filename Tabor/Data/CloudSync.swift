import CloudKit
import CoreData
import SwiftData

/// Watches iCloud sync of the book for Settings, and tidies up after what it brings in:
/// duplicates go, and stickers that arrived after their catch get drawn.
@MainActor @Observable
final class CloudSync {
    static let shared = CloudSync()
    static let containerId = "iCloud.com.filipmanikowski.tabor"

    enum State: Equatable {
        case checking
        /// The store couldn't open with CloudKit; the book is on this phone only.
        case local
        case signedOut
        /// Signed in, but iCloud can't be used now (restricted, or turned off for TABOR).
        case unavailable
        case syncing
        case synced(Date)
        case full
        case failed

        /// Whether the book is in iCloud (or on its way), so it would survive a reinstall.
        var carriesBook: Bool {
            switch self {
            case .syncing, .synced, .failed: true
            default: false
            }
        }
    }

    private(set) var account: CKAccountStatus = .couldNotDetermine
    /// Setups, imports and exports under way. Each event is posted when it starts and again
    /// when it ends, under the same id.
    private(set) var running: Set<UUID> = []
    private(set) var lastSynced: Date?
    private(set) var quotaFull = false
    private(set) var lastFailed = false
    private var tidy: Task<Void, Never>?
    private var started = false

    var state: State {
        guard TaborStore.syncs else { return .local }
        switch account {
        case .couldNotDetermine: return .checking
        case .noAccount: return .signedOut
        case .restricted, .temporarilyUnavailable: return .unavailable
        default: break
        }
        if quotaFull { return .full }
        if !running.isEmpty { return .syncing }
        if lastFailed { return .failed }
        return lastSynced.map(State.synced) ?? .syncing
    }

    func start() {
        guard !started else { return }
        started = true
        _ = TaborStore.container
        let center = NotificationCenter.default
        center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event
            MainActor.assumeIsolated { if let event { self.handle(event) } }
        }
        center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.changed() }
        }
        center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.checkAccount() }
        }
        checkAccount()
        changed()
        Task.detached(priority: .utility) { PhotoStore.moveFolderIntoStore() }
    }

    private func checkAccount() {
        guard TaborStore.syncs else { return }
        Task {
            let status = (try? await CKContainer(identifier: Self.containerId).accountStatus()) ?? .couldNotDetermine
            account = status
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        guard let end = event.endDate else {
            running.insert(event.identifier)
            return
        }
        running.remove(event.identifier)
        if event.succeeded {
            lastFailed = false
            lastSynced = end
            if event.type == .export { quotaFull = false }
            if event.type == .import { changed() }
        } else if let error = event.error {
            lastFailed = true
            if Self.isQuotaExceeded(error) { quotaFull = true }
        }
    }

    private static func isQuotaExceeded(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        if ck.code == .quotaExceeded { return true }
        return ck.partialErrorsByItemID?.values.contains { ($0 as? CKError)?.code == .quotaExceeded } ?? false
    }

    /// Something in the store changed, here or from iCloud. Waits for a burst of changes to
    /// settle, then drops duplicates and redraws pictures.
    private func changed() {
        tidy?.cancel()
        tidy = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            TaborStore.removeDuplicates(in: ModelContext(TaborStore.container))
            PhotoStore.revision.value += 1
        }
    }
}
