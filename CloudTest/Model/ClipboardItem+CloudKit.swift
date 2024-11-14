//
//  ClipboardItem+CloudKit.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 07.11.24.
//

import Foundation
import CloudKit

fileprivate extension CKRecord.FieldKey {
    static let contents = "contents"
    static let id = "id"
}

extension ClipboardItem: Syncable {
    struct RecordError: LocalizedError {
        var localizedDescription: String

        static func missingKey(_ key: CKRecord.FieldKey) -> RecordError {
            RecordError(localizedDescription: "Missing required key \(key)")
        }
    }
    
    var record: CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r[.id] = id
        if !contents.isEmpty {
            let contentReferences = contents.map { clipboardItemContent -> CKRecord.Reference in
                let contentRecordID = CKRecord.ID(
                    recordName: clipboardItemContent.id,
                    zoneID: SyncConfig.default.customZoneID
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
        guard let id = record[.id] as? String else {
            throw RecordError.missingKey(.id)
        }
        self.id = id
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
