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
        
        operation.qualityOfService = .userInitiated
        operation.database = database

        operation.modifyRecordZonesResultBlock = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                os_log("Zone created successfully", log: self.log, type: .info)
                createdCustomZone = true
            case .failure(let error):
                os_log("Failed to create custom CloudKit zone: %{public}@",
                       log: self.log,
                       type: .error,
                       String(describing: error))
                
                error.retryCloudKitOperationIfPossible(log) { self.createZone() }
            }
        }

        queue.addOperation(operation)
    }
    
    private func checkCustomZone() {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [SyncConstants.customZoneID])
        operation.qualityOfService = .userInitiated
        operation.database = database
        
        operation.fetchRecordZonesResultBlock = { [weak self] result in
            guard let self else { return }
            
            switch result {
            case .success:
                os_log("Zone verified successfully", log: self.log, type: .info)
            case .failure(let error):
                os_log("Failed to check for custom zone existence: %{public}@", log: self.log, type: .error, String(describing: error))
                
                if !error.retryCloudKitOperationIfPossible(self.log, with: { self.checkCustomZone() }) {
                    os_log("Irrecoverable error when fetching custom zone, assuming it doesn't exist: %{public}@", log: self.log, type: .error, String(describing: error))
                    createdCustomZone = false
                    createCustomZoneIfNeeded()
                }
            }
        }

        queue.addOperation(operation)
    }
}
