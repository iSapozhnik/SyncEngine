//
//  ClipboardItem+CloudKit.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 07.11.24.
//

import Foundation
import CloudKit

fileprivate extension CKRecord.FieldKey {
    static let isRemoved = "isRemoved"
    static let contents = "contents"
}

extension ClipboardItem: Syncable {
    struct RecordError: LocalizedError {
        var localizedDescription: String

        static func missingKey(_ key: CKRecord.FieldKey) -> RecordError {
            RecordError(localizedDescription: "Missing required key \(key)")
        }
    }
    
    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: SyncConstants.customZoneID)
    }
    
    var record: CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r[.isRemoved] = isRemoved
        
        if !contents.isEmpty {
            let contentReferences = contents.map { content -> CKRecord.Reference in
                let contentRecordID = CKRecord.ID(
                    recordName: content.id,
                    zoneID: SyncConstants.customZoneID
                )
                return CKRecord.Reference(
                    recordID: contentRecordID,
                    action: .deleteSelf
                )
            }
            r[.contents] = contentReferences as NSArray
        }
        
        return r
    }
    
    func recordLegacy() -> CKRecord {
        fatalError("Should not be called")
    }

    init(record: CKRecord, configure: ((inout Self) -> Void)? = nil) throws {
        guard let isRemoved = record[.isRemoved] as? Bool else {
            throw RecordError.missingKey(.isRemoved)
        }
        self.isRemoved = isRemoved
        self.id = record.recordID.recordName
        self.ckData = record.encodedSystemFields
        self.timestamp = record.creationDate ?? Date()
        self.updatedDate = record.modificationDate ?? Date()
        self.contents = [] // TODO: FixMe
        self.cloudKitRecordID = record.recordID.recordName
        configure?(&self)
    }
    
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
//        guard
//            let clientDate = clientRecord[RecordKeys.ClipboardItem.updatedDate] as? Date,
//            let serverDate = serverRecord[RecordKeys.ClipboardItem.updatedDate] as? Date
//        else {
//            return serverRecord
//        }
//
//        return clientDate > serverDate ? clientRecord : serverRecord
        
        
        // Custom logic for resolving conflicts.
        // In this example, the client values will always overwrite all server values.
        //
        // The server record has the latest changeTag and must be returned.

        // Merge all client record keys/values into the server record
        for key in clientRecord.allKeys() {
            serverRecord[key] = clientRecord[key]
        }

        return serverRecord
    }
}
