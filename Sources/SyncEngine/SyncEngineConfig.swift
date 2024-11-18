import Foundation
import CloudKit

public protocol SyncEngineConfig {
    var containerIdentifier: String { get }
    var zoneName: String { get }
    var ownerName: String? { get }
}

extension SyncEngineConfig {
    public var customZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName ?? CKCurrentUserDefaultName)
    }
}
