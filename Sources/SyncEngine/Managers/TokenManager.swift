import Foundation
import AppKit
import CloudKit
import os.log

final class TokenManager {
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "TokenManager")
    
    private let config: SyncEngineConfig
    private let defaults: UserDefaults

    init(
        syncConfig: SyncEngineConfig,
        defaults: UserDefaults
    ) {
        config = syncConfig
        self.defaults = defaults
    }
    
    lazy var privateChangeTokenKey: String = {
        return "TOKEN-\(config.zoneName)"
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
                defaults.removeObject(forKey: privateChangeTokenKey)
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
