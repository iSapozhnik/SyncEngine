//
//  SyncEngineConfig.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 14.11.24.
//

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
