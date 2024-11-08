//
//  ClipboardItemContent+CloudKit.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 08.11.24.
//

import Foundation
import CloudKit

fileprivate extension CKRecord.FieldKey {
    static let typeIdentifier = "typeIdentifier"
    static let data = "data"
    static let asset = "asset"
    static let clipboardItem = "clipboardItem"
    static let clipboardItemId = "clipboardItemId"
    static let id = "id"
}

extension ClipboardItemContent: Syncable {
    struct RecordError: LocalizedError {
        var localizedDescription: String

        static func missingKey(_ key: CKRecord.FieldKey) -> RecordError {
            RecordError(localizedDescription: "Missing required key \(key)")
        }
    }
    
    func recordLegacy() -> CKRecord {
        fatalError("Should not be called")
    }
    
    var record: CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r[.typeIdentifier] = typeIdentifier
        r[.clipboardItemId] = clipboardItemId
        r[.id] = id
        
        let parentRecordID = CKRecord.ID(recordName: clipboardItemId, zoneID: SyncConstants.customZoneID)
        r[.clipboardItem] = CKRecord.Reference(recordID: parentRecordID, action: .deleteSelf)
        
        if data.count > 1_000_000 {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: tempURL, options: [.atomic])
            } catch {
                
            }
            r[.asset] = CKAsset(fileURL: tempURL)
        } else {
            r[.data] = data
        }
        return r
    }
    
    init(record: CKRecord, configure: ((inout Self) -> Void)? = nil) throws {
        guard let id = record[.id] as? String else {
            throw RecordError.missingKey(.id)
        }
        guard let typeIdentifier = record[.typeIdentifier] as? String else {
            throw RecordError.missingKey(.typeIdentifier)
        }
        guard let clipboardItemId = record[.clipboardItemId] as? String else {
            throw RecordError.missingKey(.clipboardItemId)
        }
        guard let data = record[.data] as? Data else {
            throw RecordError.missingKey(.data)
        }
        self.typeIdentifier = typeIdentifier
        self.clipboardItemId = clipboardItemId
        self.id = id
        self.data = data
        self.ckData = record.encodedSystemFields
        self.timestamp = record.creationDate ?? Date()
        self.updatedDate = record.modificationDate ?? Date()
        self.cloudKitRecordID = record.recordID.recordName
        configure?(&self)
    }
    
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        guard
            let clientDate = clientRecord["modificationDate"] as? Date,
            let serverDate = serverRecord["modificationDate"] as? Date
        else {
            return serverRecord
        }
        
        return clientDate > serverDate ? clientRecord : serverRecord
    }
}
