//
//  CKConstants.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 14.11.24.
//

import Foundation

struct SyncConfig: SyncEngineConfig {
    let containerIdentifier = "iCloud.com.isapozhnik.CloudTest0"
    let zoneName = "CustomZone0"
    let ownerName: String? = nil
    
    static let `default` = Self()
}
