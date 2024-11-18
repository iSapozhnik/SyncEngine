//
//  SyncEngine+Upload.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 16.11.24.
//

import Foundation
import os.log
import CloudKit

extension SyncEngine {
    func upload(_ models: [any Syncable]) async throws {
        defer { lastState = .idle }
        guard try await syncConditionsMet() else { return }
        lastState = .loading
        
        os_log("%{public}@", log: log, type: .debug, #function)
        buffer.append(contentsOf: models)
        try await uploadRecords(models.map { $0.record })
    }
    
    func uploadLocalDataNotUploadedYet(retryCount: Int = Constants.retryCount) async throws {
        defer {
            lastState = .idle
        }
        
        guard retryCount > 0 else {
            throw EngineError.failedFetchingRemoteChanges
        }
        
        os_log("%{public}@", log: log, type: .debug, #function)
        
        let models = buffer.filter { $0.ckData == nil }
        guard !models.isEmpty else { return }
        
        os_log("Found %d local model(s) which haven't been uploaded yet.", log: self.log, type: .debug, models.count)
        
        let records = models.map { $0.record }
        
        do {
            lastState = .loading
            try await uploadRecords(records)
        } catch {
            os_log(
                "Failed to upload local recors that were not uploaded yet. Retry: %{public}@",
                log: self.log,
                type: .debug,
                retryCount
            )
            if await error.retryCloudKitOperationIfPossible(log) {
                try await uploadLocalDataNotUploadedYet(retryCount: retryCount - 1)
            } else {
                throw error
            }
        }
    }
    
    private func uploadRecords(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        
        let progress = Progress(totalUnitCount: Int64(records.count))
        progress.isCancellable = true
        progress.isPausable = true
        
        os_log("%{public}@ with %d record(s)", log: log, type: .debug, #function, records.count)
        
        let modifyResult = try await privateDatabase.modifyRecords(
            saving: records,
            deleting: []
        )
        
        var serverRecords: [CKRecord] = []
        
        for (recordID, result) in modifyResult.saveResults {
            do {
                let savedRecord = try result.get()
                progress.completedUnitCount += 1

                await MainActor.run {
                    self.progressHandler?(Double(progress.fractionCompleted))
                }
                serverRecords.append(savedRecord)
            } catch let error as CKError {
                if error.isCloudKitConflict.hasConflict, let conflictData = error.isCloudKitConflict.conflictData {
                    guard let syncableType = getType(for: conflictData.localRecord.recordType) else {
                        throw error
                    }
                    
                    let resolvedRecord = syncableType.resolveConflict(
                        clientRecord: conflictData.localRecord,
                        serverRecord: conflictData.remoteRecord
                    )
                    
                    // Handle the resolved conflict by saving it
                    let conflictResult = try await privateDatabase.modifyRecords(
                        saving: [resolvedRecord],
                        deleting: [],
                        savePolicy: .ifServerRecordUnchanged
                    )
                    if let savedRecord = try conflictResult.saveResults[recordID]?.get() {
                        await MainActor.run {
                            self.progressHandler?(Double(progress.fractionCompleted))
                        }
                        serverRecords.append(savedRecord)
                    }
                } else {
                    throw error
                }
            }
        }
        let groupedServerRecords: [String: [CKRecord]] = Dictionary(grouping: serverRecords, by: \.recordType)
        await updateLocalModelsAfterUpload(with: groupedServerRecords)
    }
    
    private func updateLocalModelsAfterUpload(with records: [String: [CKRecord]]) async {
        var convertedModels: [String: [any Syncable]] = [:]
        for (key, records) in records {
            let models = records.compactMap { (record: CKRecord) -> (any Syncable)? in
                guard var model = buffer.first(where: { $0.id == record.recordID.recordName }) else { return nil }
                model.ckData = record.encodedSystemFields
                buffer.removeAll(where: { $0.id == record.recordID.recordName })
                return model
            }
            convertedModels[key] = models
        }
        
        guard !convertedModels.isEmpty else { return }
        await MainActor.run { [convertedModels] in
            self.didUpdateModels(convertedModels)
        }
    }
}
