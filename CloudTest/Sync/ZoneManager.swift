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
    
    init(userDefaults: UserDefaults, database: CKDatabase) {
        self.userDefaults = userDefaults
        self.database = database
    }
    
    @discardableResult
    func createCustomZoneIfNeeded() async throws -> Bool {
        os_log("⏳ Started setting up Zone.",
               log: log,
               type: .info
        )
        
        if createdCustomZone {
            os_log("Already have custom zone, skipping creation but checking if zone really exists", log: log, type: .debug)

            try await checkCustomZone()
        } else {
            os_log("Creating CloudKit zone %@", log: log, type: .info, SyncConstants.customZoneID.zoneName)
            
            try await createZone()
        }
        
        os_log("✅ Finished setting up Zone.",
               log: log,
               type: .info
        )
        
        return createdCustomZone
    }
    
    private func createZone() async throws {
        let zone = CKRecordZone(zoneID: SyncConstants.customZoneID)
        
        do {
            let zone = try await database.save(zone)
            os_log("Zone %{public}@ created successfully", log: self.log, type: .info, zone.zoneID.zoneName)
            createdCustomZone = true
        } catch {
            os_log("Failed to create custom CloudKit zone: %{public}@",
                   log: self.log,
                   type: .error,
                   String(describing: error))
            
            if await error.retryCloudKitOperationIfPossible(log) {
                try await createZone()
            }
        }
    }
    
    private func checkCustomZone() async throws {
        do {
            let fetchedZone = try await database.recordZone(for: SyncConstants.customZoneID)
            os_log("Zone %{public}@ verified successfully", log: self.log, type: .info, fetchedZone.zoneID.zoneName)
        } catch {
            os_log("Failed to check for custom zone existence: %{public}@", log: self.log, type: .error, String(describing: error))
            
            if await error.retryCloudKitOperationIfPossible(log) {
                try await checkCustomZone()
            }
                
            os_log("Irrecoverable error when fetching custom zone, assuming it doesn't exist: %{public}@", log: self.log, type: .error, String(describing: error))
            createdCustomZone = false
            try await createCustomZoneIfNeeded()
        }
    }
}
