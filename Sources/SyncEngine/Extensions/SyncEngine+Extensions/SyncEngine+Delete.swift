import Foundation
import CloudKit
import os.log

extension SyncEngine {
    
    @discardableResult
    public func delete(_ models: [any Syncable]) async throws -> [CKRecord.ID] {
        defer { lastState = .idle }

        let recordIDs = models.map { $0.record.recordID }
        guard try await syncConditionsMet() else {
            pendingOperationsManager.addPendingDeletions(recordIDs: recordIDs.map(\.recordName))
            return []
        }
        lastState = .loading
        
        os_log("%{public}@", log: log, type: .debug, #function)
        
        let result = try await deleteRecords(recordIDs)
        
        await MainActor.run {
            self.didDeleteModels(models.map(\.id))
        }
        return result
    }
    
    @discardableResult
    public func delete(_ recordIDs: [String]) async throws -> [CKRecord.ID] {
        defer { lastState = .idle }
        
        guard try await syncConditionsMet() else {
            pendingOperationsManager.addPendingDeletions(recordIDs: recordIDs)
            return []
        }
        lastState = .loading
        
        os_log("%{public}@", log: log, type: .debug, #function)
        
        let recordIDs = recordIDs.map { CKRecord.ID(recordName: $0, zoneID: config.customZoneID) }
        let result = try await deleteRecords(recordIDs)
        
        await MainActor.run {
            self.didDeleteModels(recordIDs.map(\.recordName))
        }
        return result
    }
    
    @discardableResult
    private func deleteRecords(_ recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        guard !recordIDs.isEmpty else { return [] }
        
        let progress = Progress(totalUnitCount: Int64(recordIDs.count))
        progress.isCancellable = true
        progress.isPausable = true
        
        os_log("%{public}@ with %d record(s)", log: log, type: .debug, #function, recordIDs.count)
        
        let modifyResult = try await privateDatabase.modifyRecords(
            saving: [],
            deleting: recordIDs
        )
        
        var deletedRecordIDs: [CKRecord.ID] = []
        for (recordID, result) in modifyResult.deleteResults {
            do {
                _ = try result.get()
                progress.completedUnitCount += 1
                deletedRecordIDs.append(recordID)
                await MainActor.run {
                    self.progressHandler?(Double(progress.fractionCompleted))
                }
            } catch let error as CKError {
                // If the record doesn't exist, we can consider it deleted
                if error.code == .unknownItem {
                    progress.completedUnitCount += 1
                    deletedRecordIDs.append(recordID)
                    await MainActor.run {
                        self.progressHandler?(Double(progress.fractionCompleted))
                    }
                    continue
                }
                throw error
            }
        }
        return deletedRecordIDs
    }
}
