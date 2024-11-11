//
//  SubscriptionManager.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 09.11.24.
//

import Foundation
import CloudKit
import os.log

final class SubscriptionManager {
    private let database: CKDatabase
    private let userDefaults: UserDefaults
    private let log = OSLog(subsystem: SyncConstants.subsystemName, category: "SubscriptionManager")
    
    private lazy var createdPrivateSubscriptionKey: String = {
        return "CREATEDSUBDB-\(SyncConstants.customZoneID.zoneName)"
    }()
    
    private var subscriptionsRegistry: [String: CKSubscription.ID] {
        get {
            userDefaults.dictionary(forKey: createdPrivateSubscriptionKey) as? [String: CKSubscription.ID] ?? [:]
        }
        set {
            userDefaults.set(newValue, forKey: createdPrivateSubscriptionKey)
        }
    }
    
    init(userDefaults: UserDefaults, database: CKDatabase) {
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
    
    private func createSubscriptions(for recordTypes: [String]) async throws {
        let subscriptions = recordTypes.map { makeSubscriptionObject(for: $0) }
        
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for subscriptionPair in subscriptions {
                    group.addTask {
                        do {
                            os_log("🔄 Creting private subscription for %{public}@",
                                   log: self.log,
                                   type: .info,
                                   subscriptionPair.recordType
                            )
                            let savedSubscription = try await self.database.save(subscriptionPair.subscription)
                            os_log("Private subscription for %{public}@ created successfully",
                                  log: self.log,
                                  type: .info,
                                   subscriptionPair.recordType
                            )
                            self.subscriptionsRegistry[subscriptionPair.recordType] = savedSubscription.subscriptionID
                        } catch {
                            os_log("Failed to create private CloudKit subscription: %{public}@",
                                  log: self.log,
                                  type: .error,
                                  String(describing: error))
                            throw error
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            if await error.retryCloudKitOperationIfPossible(log) {
                try await createSubscriptions(for: recordTypes)
            } else {
                throw error
            }
        }
    }
    
    private func checkSubscriptions(for subscriptionIDs: [CKSubscription.ID]) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for subscriptionID in subscriptionIDs {
                    group.addTask {
                        do {
                            let subscription = try await self.database.subscription(for: subscriptionID)
                            os_log("Private subscription %{public}@ verified successfully",
                                   log: self.log,
                                   type: .info,
                                   subscription.subscriptionID
                            )
                        } catch {
                            guard let recordType = self.subscriptionsRegistry.first(where: { $0.value == subscriptionID })?.key else {
                                os_log("Could not match verified subscription with requested subscription. subscriptionID: %{public}@",
                                       log: self.log,
                                       type: .error,
                                       subscriptionID
                                )
                                return
                            }
                            
                            os_log("Private subscription exists locally, but does not exist in CloudKit: %{public}@",
                                  log: self.log,
                                  type: .error,
                                  String(describing: error))
                            
                            if await error.retryCloudKitOperationIfPossible(self.log) {
                                try await self.createSubscriptions(for: [recordType])
                            } else {
                                os_log("Irrecoverable error when checking private subscription, assuming it doesn't exist: %{public}@",
                                      log: self.log,
                                      type: .error,
                                      String(describing: error))
                                self.subscriptionsRegistry[recordType] = nil
                                try await self.createSubscriptions(for: [recordType])
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            throw error
        }
    }
    
    private func makeSubscriptionObject(for recordType: String) -> (recordType: String, subscription: CKSubscription) {
        let subscription = CKRecordZoneSubscription(
            zoneID: SyncConstants.customZoneID,
            subscriptionID: subscriptionId(for: recordType)
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        
        subscription.notificationInfo = notificationInfo
        subscription.recordType = recordType
        return (recordType, subscription)
    }
    
    private func subscriptionId(for recortType: String) -> String {
        return "\(SyncConstants.customZoneID.zoneName).\(recortType).subscription"
    }
}

