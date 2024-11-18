import Foundation
import os.log
import CloudKit

extension SyncEngine {
    
    @discardableResult
    public func processSubscriptionNotification(with userInfo: [AnyHashable : Any]) -> Bool {
        os_log("%{public}@", log: log, type: .debug, #function)

        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_log("Not a CKNotification", log: log, type: .error)
            return false
        }

        guard subscriptionManager.shouldHandleSubscriptionID(notification.subscriptionID) else {
            os_log("Not our subscription ID", log: log, type: .debug)
            return false
        }

        os_log("Received remote CloudKit notification for user data", log: log, type: .debug)

        Task { try await fetchChanges() }

        return true
    }
    
    private func fetchChanges() async throws {
        try await taskSerializer.add {
            try await self.fetchRemoteChanges()
        }
    }
}
