import Foundation
import CloudKit
import os.log

final class ZoneManager {
    enum Constants {
        static let retryCount: Int = 3
    }
    
    enum ManagerError: Error {
        case failedCreatingZone
        case failedCheckingZone
    }
    
    private let config: SyncEngineConfig
    private let userDefaults: UserDefaults
    private let database: CKDatabase
    
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "ZoneManager")

    private lazy var createdCustomZoneKey: String = {
        return "CREATEDZONE-\(config.zoneName)"
    }()

    private var createdCustomZone: Bool {
        get { userDefaults.bool(forKey: createdCustomZoneKey) }
        set { userDefaults.set(newValue, forKey: createdCustomZoneKey) }
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
    
    @discardableResult
    func createCustomZoneIfNeeded() async throws -> Bool {
        os_log("⏳ Started setting up Zone.", log: log, type: .info)
        
        if createdCustomZone {
            os_log("Already have custom zone, skipping creation but checking if zone really exists",
                   log: log, type: .debug)
            try await checkCustomZone()
        } else {
            os_log("Creating CloudKit zone %@",
                   log: log, type: .info,
                   config.zoneName)
            try await createZone()
        }
        
        os_log("✅ Finished setting up Zone.", log: log, type: .info)
        return createdCustomZone
    }
    
    private func createZone(retryCount: Int = Constants.retryCount) async throws {
        guard retryCount > 0 else {
            throw ManagerError.failedCreatingZone
        }
        
        let zone = CKRecordZone(zoneID: config.customZoneID)
        
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
                try await createZone(retryCount: retryCount - 1)
            } else {
                throw error
            }
        }
    }
    
    private func checkCustomZone(retryCount: Int = Constants.retryCount) async throws {
        guard retryCount > 0 else {
            throw ManagerError.failedCheckingZone
        }
        
        do {
            let fetchedZone = try await database.recordZone(for: config.customZoneID)
            os_log("Zone %{public}@ verified successfully", log: self.log, type: .info, fetchedZone.zoneID.zoneName)
        } catch {
            os_log("Failed to check for custom zone existence: %{public}@", log: self.log, type: .error, String(describing: error))
            
            if await error.retryCloudKitOperationIfPossible(log) {
                try await checkCustomZone(retryCount: retryCount - 1)
            } else {
                os_log("Irrecoverable error when fetching custom zone, assuming it doesn't exist: %{public}@", log: self.log, type: .error, String(describing: error))
                createdCustomZone = false
                try await createCustomZoneIfNeeded()
            }
        }
    }
}
