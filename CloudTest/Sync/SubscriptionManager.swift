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
    private let queue: OperationQueue
    private let userDefaults: UserDefaults
    private let database: CKDatabase
    
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
    
    init(queue: OperationQueue, userDefaults: UserDefaults, database: CKDatabase) {
        self.queue = queue
        self.userDefaults = userDefaults
        self.database = database
    }
    
    func shouldHandleSubscriptionID(_ subscriptionID: String?) -> Bool {
        guard let subscriptionID else { return false }
        return subscriptionsRegistry.values.contains(subscriptionID)
    }
    
    func createPrivateSubscriptionsIfNeeded(recordTypes: [String]) -> Bool {
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
        
        checkSubscriptions(for: check)
        createSubscriptions(for: create)
        
        queue.waitUntilAllOperationsAreFinished()
        
        return true
    }
    
    private func createSubscriptions(for recordTypes: [String]) {
        var subscriptions: [String: CKSubscription] = [:]
        recordTypes.forEach { subscriptions[$0] = makeSubscriptionObject(for: $0) }
        
        let operation = CKModifySubscriptionsOperation(
            subscriptionsToSave: Array(subscriptions.values),
            subscriptionIDsToDelete: nil
        )

        operation.database = database
        operation.qualityOfService = .userInitiated
        
        operation.perSubscriptionSaveBlock = { [weak self] subscriptionID, saveResult in
            guard let self else { return }
            guard let recordType = subscriptions.first(where: { $0.value.subscriptionID == subscriptionID })?.key else {
                os_log("Could not match registered subscription with requested subscription. subscriptionID: %{public}@",
                       log: self.log,
                       type: .error,
                       subscriptionID
                )
                return
            }
            switch saveResult {
            case .success(let subscription):
                os_log("Private subscription for %{public}@ created successfully", log: self.log, type: .info, recordType)
                subscriptionsRegistry[recordType] = subscription.subscriptionID
            case .failure(let error):
                os_log("Failed to create private CloudKit subscription: %{public}@",
                       log: self.log,
                       type: .error,
                       String(describing: error))
                error.retryCloudKitOperationIfPossible(log) { self.createSubscriptions(for: [recordType]) }
            }
        }
        queue.addOperation(operation)
    }
    
    private func checkSubscriptions(for subscriptionIDs: [CKSubscription.ID]) {
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: subscriptionIDs)
        operation.database = database
        operation.qualityOfService = .userInitiated
        
        operation.perSubscriptionResultBlock = { [weak self] subscriptionID, saveResult in
            guard let self else { return }
            
            switch saveResult {
            case .success:
                os_log("Private subscription verified successfully", log: self.log, type: .info)
            case .failure(let error):
                guard let recordType = subscriptionsRegistry.first(where: { $0.value == subscriptionID })?.key else {
                    os_log("Could not match verified subscription with requested subscription. subscriptionID: %{public}@",
                           log: self.log,
                           type: .error,
                           subscriptionID
                    )
                    return
                }
                
                os_log("Private subscription exists locally, but does not exist in CloudKit: %{public}@.",
                       log: self.log,
                       type: .error,
                       String(describing: error))
                if !error.retryCloudKitOperationIfPossible(log, with: { self.createSubscriptions(for: [recordType]) }) {
                    os_log("Irrecoverable error when checking private subscription, assuming it doesn't exist: %{public}@", log: self.log, type: .error, String(describing: error))
                    subscriptionsRegistry[recordType] = nil
                    createSubscriptions(for: [recordType])
                }
            }
        }
        
        queue.addOperation(operation)
    }
    
    private func makeSubscriptionObject(for recordType: String) -> CKSubscription {
        let subscription = CKRecordZoneSubscription(
            zoneID: SyncConstants.customZoneID,
            subscriptionID: subscriptionId(for: recordType)
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true

        subscription.notificationInfo = notificationInfo
        subscription.recordType = recordType
        return subscription
    }
    
    private func subscriptionId(for recortType: String) -> String {
        return "\(SyncConstants.customZoneID.zoneName).\(recortType).subscription"
    }
}

