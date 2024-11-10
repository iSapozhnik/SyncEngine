//
//  ZoneManager.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 10.11.24.
//

import Foundation
import CloudKit
import os.log

final class ZoneManager {
    private let queue: OperationQueue
    private let userDefaults: UserDefaults
    private let database: CKDatabase
    
    private let log = OSLog(subsystem: SyncConstants.subsystemName, category: "ZoneManager")

    private lazy var createdCustomZoneKey: String = {
        return "CREATEDZONE-\(SyncConstants.customZoneID.zoneName)"
    }()

    private var createdCustomZone: Bool {
        get {
            return userDefaults.bool(forKey: createdCustomZoneKey)
        }
        set {
            userDefaults.set(newValue, forKey: createdCustomZoneKey)
        }
    }
    
    init(queue: OperationQueue, userDefaults: UserDefaults, database: CKDatabase) {
        self.queue = queue
        self.userDefaults = userDefaults
        self.database = database
    }
    
    @discardableResult
    func createCustomZoneIfNeeded() -> Bool {
        
        if createdCustomZone {
            os_log("Already have custom zone, skipping creation but checking if zone really exists", log: log, type: .debug)

            checkCustomZone()
        } else {
            os_log("Creating CloudKit zone %@", log: log, type: .info, SyncConstants.customZoneID.zoneName)
            
            createZone()
        }
        
        queue.waitUntilAllOperationsAreFinished()
        return createdCustomZone
    }
    
    private func createZone() {
        let zone = CKRecordZone(zoneID: SyncConstants.customZoneID)
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)

        operation.modifyRecordZonesCompletionBlock = { [weak self] _, _, error in
            guard let self else { return }

            if let error = error {
                os_log("Failed to create custom CloudKit zone: %{public}@",
                       log: self.log,
                       type: .error,
                       String(describing: error))

                error.retryCloudKitOperationIfPossible(self.log) { self.createCustomZoneIfNeeded() }
            } else {
                os_log("Zone created successfully", log: self.log, type: .info)
                self.createdCustomZone = true
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queue.addOperation(operation)
    }
    
    private func checkCustomZone() {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [SyncConstants.customZoneID])
        operation.qualityOfService = .userInitiated
        operation.database = database

        operation.fetchRecordZonesCompletionBlock = { [weak self] ids, error in
            guard let self else { return }

            if let error = error {
                os_log("Failed to check for custom zone existence: %{public}@", log: self.log, type: .error, String(describing: error))

                if !error.retryCloudKitOperationIfPossible(self.log, with: { self.checkCustomZone() }) {
                    os_log("Irrecoverable error when fetching custom zone, assuming it doesn't exist: %{public}@", log: self.log, type: .error, String(describing: error))

                    DispatchQueue.main.async {
                        self.createdCustomZone = false
                        self.createCustomZoneIfNeeded()
                    }
                }
            } else if ids == nil || ids?.count == 0 {
                os_log("Custom zone reported as existing, but it doesn't exist. Creating.", log: self.log, type: .error)
                self.createdCustomZone = false
                self.createCustomZoneIfNeeded()
            }
        }

        queue.addOperation(operation)
    }
}
