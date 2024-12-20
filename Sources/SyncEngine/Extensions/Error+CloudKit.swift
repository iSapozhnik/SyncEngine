import Foundation
import CloudKit
import os.log

public struct ConflictData {
    let localRecord: CKRecord
    let remoteRecord: CKRecord
}

public extension Error {
    typealias Conflict = (hasConflict: Bool, conflictData: ConflictData?)

    /// Whether this error is a CloudKit server record changed error, representing a record conflict
    var isCloudKitConflict: Conflict {
        guard let effectiveError = self as? CKError else { return (hasConflict: false, conflictData: nil) }

        if effectiveError.code == CKError.Code.serverRecordChanged {
            let localRecord = effectiveError.userInfo[CKRecordChangedErrorClientRecordKey] as? CKRecord
            let remoteRecord = effectiveError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
            
            // if we can not get records from the error - we can not resolve the conflict 🤷🏼
            guard let localRecord, let remoteRecord else { return (hasConflict: false, conflictData: nil) }
            return (hasConflict: true, conflictData: ConflictData(localRecord: localRecord, remoteRecord: remoteRecord))
        } else {
            return (hasConflict: false, conflictData: nil)
        }
    }

    /// Whether this error represents a "zone not found" or a "user deleted zone" error
    var isCloudKitZoneDeleted: Bool {
        guard let effectiveError = self as? CKError else { return false }

        return [.zoneNotFound, .userDeletedZone].contains(effectiveError.code)
    }

    /// Uses the `resolver` closure to resolve a conflict, returning the conflict-free record
    ///
    /// - Parameter resolver: A closure that will receive the client record as the first param and the server record as the second param.
    /// This closure is responsible for handling the conflict and returning the conflict-free record.
    /// - Returns: The conflict-free record returned by `resolver`
    func resolveConflict(with resolver: (CKRecord, CKRecord) -> CKRecord?) -> CKRecord? {
        guard let effectiveError = self as? CKError else {
            os_log("resolveConflict called on an error that was not a CKError. The error was %{public}@",
                   log: .default,
                   type: .fault,
                   String(describing: self))
            return nil
        }

        guard effectiveError.code == .serverRecordChanged else {
            os_log("resolveConflict called on a CKError that was not a serverRecordChanged error. The error was %{public}@",
                   log: .default,
                   type: .fault,
                   String(describing: effectiveError))
            return nil
        }

        guard let clientRecord = effectiveError.userInfo[CKRecordChangedErrorClientRecordKey] as? CKRecord else {
            os_log("Failed to obtain client record from serverRecordChanged error. The error was %{public}@",
                   log: .default,
                   type: .fault,
                   String(describing: effectiveError))
            return nil
        }

        guard let serverRecord = effectiveError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
            os_log("Failed to obtain server record from serverRecordChanged error. The error was %{public}@",
                   log: .default,
                   type: .fault,
                   String(describing: effectiveError))
            return nil
        }

        return resolver(clientRecord, serverRecord)
    }

    /// Retries a CloudKit operation if the error suggests it
    ///
    /// - Parameters:
    ///   - log: The logger to use for logging information about the error handling, uses the default one if not set
    ///   - block: The block that will execute the operation later if it can be retried
    /// - Returns: Whether or not it was possible to retry the operation
    @discardableResult func retryCloudKitOperationIfPossible(_ log: OSLog? = nil, with block: @escaping () -> Void) -> Bool {
        let effectiveLog: OSLog = log ?? .default

        guard let effectiveError = self as? CKError else { return false }

        guard let retryDelay: Double = effectiveError.retryAfterSeconds else {
            os_log("Error is not recoverable", log: effectiveLog, type: .error)
            return false
        }

        os_log("Error is recoverable. Will retry after %{public}f seconds", log: effectiveLog, type: .error, retryDelay)

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
            block()
        }

        return true
    }

    func retryCloudKitOperationIfPossible(_ log: OSLog? = nil) async -> Bool {
        let effectiveLog: OSLog = log ?? .default

        guard let effectiveError = self as? CKError else { return false }

        guard let retryDelay: Double = effectiveError.retryAfterSeconds else {
            os_log("Error is not recoverable", log: effectiveLog, type: .error)
            return false
        }

        os_log("Error is recoverable. Will retry after %{public}f seconds", log: effectiveLog, type: .error, retryDelay)

        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        
        return true
    }

}
