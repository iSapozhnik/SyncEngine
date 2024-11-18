import Foundation
import CloudKit

protocol SyncEngineConfig {
    var containerIdentifier: String { get }
    var zoneName: String { get }
    var ownerName: String? { get }
}

extension SyncEngineConfig {
    var customZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName ?? CKCurrentUserDefaultName)
    }
}
