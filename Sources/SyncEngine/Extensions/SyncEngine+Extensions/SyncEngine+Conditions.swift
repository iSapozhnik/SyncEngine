//
//  SyncEngine+Conditions.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 16.11.24.
//

import Foundation
import os.log

extension SyncEngine {
    func syncConditionsMet() async throws -> Bool {
        guard networkMiddleware.isNetworkAvailable else {
            os_log("❌ Cannot start sync - no network connection", log: log, type: .error)
            return false
        }
        
        guard try await requestPermission() else {
            os_log("❌ Cannot start sync - no iCloud account", log: log, type: .error)
            return false
        }
        
        return true
    }
    
    func requestPermission() async throws -> Bool {
        await accountMiddleware.refreshStatus()
        return accountMiddleware.lastKnownStatus == .available
    }
}
