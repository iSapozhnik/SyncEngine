import Foundation
import CloudKit
import os.log

final class SubscriptionManager {
    enum Constants {
        static let retryCount: Int = 3
    }

    enum ManagerError: Error {
        case failedCreatingSubscription
        case failedCheckingSubscription
    }
    
    private let database: CKDatabase
    private let userDefaults: UserDefaults
    private let config: SyncEngineConfig
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "SubscriptionManager")
    
    private lazy var createdPrivateSubscriptionKey: String = {
        return "CREATEDSUBDB-\(config.zoneName)"
    }()
    
    private var subscriptionsRegistry: [String: CKSubscription.ID] {
        get {
            userDefaults.dictionary(forKey: createdPrivateSubscriptionKey) as? [String: CKSubscription.ID] ?? [:]
        }
        set {
            userDefaults.set(newValue, forKey: createdPrivateSubscriptionKey)
        }
    }
    
    init(
        syncConfig: SyncEngineConfig,
        userDefaults: UserDefaults,
        database: CKDatabase
    ) {
        config = syncConfig
        self.userDefaults = userDefaults
        self.database = database
    }
    
    func shouldHandleSubscriptionID(_ subscriptionID: String?) -> Bool {
        guard let subscriptionID else { return false }
        return subscriptionsRegistry.values.contains(subscriptionID)
    }
    
    func createPrivateSubscriptionsIfNeeded(recordTypes: [String]) async throws -> Bool {
        os_log("⏳ Started processing subscriptions",
               log: log,
               type: .info
        )
        var check: [CKSubscription.ID] = []
        var create: [String] = []
        
        for recordType in recordTypes {
            if let subscriptionId = subscriptionsRegistry[recordType] {
                os_log(
                    "%{public}@ already subscribed to private database changes, skipping subscription but checking if it really exists",
                    log: log,
                    type: .debug,
                    recordType
                )
                check.append(subscriptionId)
            } else {
                os_log(
                    "No suscription to private database changes for %{public}@, creating one",
                    log: log,
                    type: .debug,
                    recordType
                )
                create.append(recordType)
            }
        }
        
        if !check.isEmpty {
            try await checkSubscriptions(for: check)
        }
        if !create.isEmpty {
            try await createSubscriptions(for: create)
        }
        os_log("✅ Finished processing subscriptions.",
               log: log,
               type: .info
        )
        return true
    }
    
    private func createSubscriptions(
        for recordTypes: [String],
        retryCount: Int = Constants.retryCount
    ) async throws {
        guard retryCount > 0 else {
            throw ManagerError.failedCreatingSubscription
        }

        let subscriptions = recordTypes.map { makeSubscriptionObject(for: $0) }
        
        do {
            os_log("✉️ Creting private subscription for types: %{public}@",
                   log: self.log,
                   type: .info,
                   recordTypes.joined(separator: ", ")
            )
            let savedSubscriptions = try await database.modifySubscriptions(saving: subscriptions.map(\.subscription), deleting: []).saveResults.compactMap { try $0.value.get() }
            for (subscription, recordType) in zip(savedSubscriptions, recordTypes) {
                subscriptionsRegistry[recordType] = subscription.subscriptionID
                os_log("✉️ Private subscription for %{public}@ created successfully",
                       log: self.log,
                       type: .info,
                       recordType)
            }
            
        } catch {
            os_log("✉️ Failed to create subscriptions: %{public}@",
                   log: log,
                   type: .error,
                   String(describing: error))
               
            if await error.retryCloudKitOperationIfPossible(log) {
                try await createSubscriptions(for: recordTypes, retryCount: retryCount - 1)
            } else {
                throw error
            }
        }
    }
    
    private func checkSubscriptions(
        for subscriptionIDs: [CKSubscription.ID],
        retryCount: Int = Constants.retryCount
    ) async throws {
        guard retryCount > 0 else {
            throw ManagerError.failedCheckingSubscription
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for subscriptionID in subscriptionIDs {
                    group.addTask {
                        do {
                            let subscription = try await self.database.subscription(for: subscriptionID)
                            os_log("✉️ Private subscription %{public}@ verified successfully",
                                   log: self.log,
                                   type: .info,
                                   subscription.subscriptionID
                            )
                        } catch {
                            guard let recordType = self.subscriptionsRegistry.first(where: { $0.value == subscriptionID })?.key else {
                                os_log("✉️ Could not match verified subscription with requested subscription. subscriptionID: %{public}@",
                                       log: self.log,
                                       type: .error,
                                       subscriptionID
                                )
                                return
                            }
                            
                            os_log("✉️ Private subscription exists locally, but does not exist in CloudKit: %{public}@",
                                  log: self.log,
                                  type: .error,
                                  String(describing: error))
                            
                            if await error.retryCloudKitOperationIfPossible(self.log) {
                                try await self.createSubscriptions(for: [recordType], retryCount: retryCount - 1)
                            } else {
                                os_log("✉️ Irrecoverable error when checking private subscription, assuming it doesn't exist: %{public}@",
                                      log: self.log,
                                      type: .error,
                                      String(describing: error))
                                self.subscriptionsRegistry[recordType] = nil
                                try await self.createSubscriptions(for: [recordType], retryCount: retryCount - 1)
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            os_log("✉️ Failed to check subscriptions: %{public}@",
                   log: log,
                   type: .error,
                   String(describing: error))
               
            if await error.retryCloudKitOperationIfPossible(log) {
                try await checkSubscriptions(for: subscriptionIDs, retryCount: retryCount - 1)
            } else {
                throw error
            }
        }
    }
    
    private func makeSubscriptionObject(for recordType: String) -> (recordType: String, subscription: CKSubscription) {
        let subscription = CKRecordZoneSubscription(
            zoneID: config.customZoneID,
            subscriptionID: subscriptionId(for: recordType)
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        
        subscription.notificationInfo = notificationInfo
        subscription.recordType = recordType
        return (recordType, subscription)
    }
    
    private func subscriptionId(for recortType: String) -> String {
        return "\(config.zoneName).\(recortType).subscription"
    }
}

