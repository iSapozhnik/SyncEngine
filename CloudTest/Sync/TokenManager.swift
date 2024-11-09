//
//  TokenManager.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 09.11.24.
//

import Foundation
import AppKit
import CloudKit
import os.log

final class TokenManager {
    private let log = OSLog(subsystem: SyncConstants.subsystemName, category: "TokenManager")
    
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }
    
    lazy var privateChangeTokenKey: String = {
        return "TOKEN-\(SyncConstants.customZoneID.zoneName)"
    }()

    var changeToken: CKServerChangeToken? {
        get {
            guard let data = defaults.data(forKey: privateChangeTokenKey) else { return nil }
            guard !data.isEmpty else { return nil }

            do {
                let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)

                return token
            } catch {
                os_log("Failed to decode CKServerChangeToken from defaults key privateChangeToken", log: log, type: .error)
                return nil
            }
        }
        set {
            guard let newValue else {
                defaults.setValue(Data(), forKey: privateChangeTokenKey)
                return
            }

            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true)

                defaults.set(data, forKey: privateChangeTokenKey)
            } catch {
                os_log("Failed to encode private change token: %{public}@", log: self.log, type: .error, String(describing: error))
            }
        }
    }
}
