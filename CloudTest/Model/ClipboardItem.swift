import AppKit
import CloudKit

// MARK: - ClipboardItem
struct ClipboardItem {
    /// Used to store the encoded `CKRecord.ID` so that local records can be matched with
    /// records on the server. This ensures updates don't cause duplication of records.
    var ckData: Data? = nil
    let id: String
    let timestamp: Date
    let updatedDate: Date
    let isRemoved: Bool
    let cloudKitRecordID: String?
    let contents: [ClipboardItemContent]
}

// MARK: - Record Keys
extension RecordKeys {
    
    struct ClipboardItemContent {
        static var id: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "id") }
        static var clipboardItemId: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "clipboardItemId") }
        static var typeIdentifier: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "typeIdentifier") }
        static var data: RecordKeyPath<NSData> { RecordKeyPath(rawValue: "data") }
        static var timestamp: RecordKeyPath<NSDate> { RecordKeyPath(rawValue: "timestamp") }
        static var updatedDate: RecordKeyPath<NSDate> { RecordKeyPath(rawValue: "updatedDate") }
        static var isRemoved: RecordKeyPath<NSNumber> { RecordKeyPath(rawValue: "isRemoved") }
        static var parent: RecordKeyPath<CKRecord.Reference> { RecordKeyPath(rawValue: "parent") }
    }
}

// MARK: - ClipboardItemContent
struct ClipboardItemContent: CloudKitRecord {
    var ckData: Data? = nil
    let id: String
    let clipboardItemId: String
    let typeIdentifier: String
    let data: Data
    let timestamp: Date
    let updatedDate: Date
    let isRemoved: Bool
    let cloudKitRecordID: String?
    
    static var recordType: String { "ClipboardItemContent" }
    
    var recordKeys: [String: CKRecordValue] {
        var keys: [String: CKRecordValue] = [
            RecordKeys.ClipboardItemContent.id.rawValue: id as NSString,
            RecordKeys.ClipboardItemContent.clipboardItemId.rawValue: clipboardItemId as NSString,
            RecordKeys.ClipboardItemContent.typeIdentifier.rawValue: typeIdentifier as NSString,
            RecordKeys.ClipboardItemContent.timestamp.rawValue: timestamp as NSDate,
            RecordKeys.ClipboardItemContent.updatedDate.rawValue: updatedDate as NSDate,
            RecordKeys.ClipboardItemContent.isRemoved.rawValue: isRemoved as NSNumber
        ]
        
        // Add parent reference
        let parentRecordID = CKRecord.ID(recordName: clipboardItemId, zoneID: SyncConstants.customZoneID)
        keys[RecordKeys.ClipboardItemContent.parent.rawValue] = CKRecord.Reference(
            recordID: parentRecordID,
            action: .none
        )
        
        if data.count > 1_000_000 { // 1MB threshold
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: tempURL)
            } catch {
                
            }
            let asset = CKAsset(fileURL: tempURL)
            keys[RecordKeys.ClipboardItemContent.data.rawValue] = asset
        } else {
            keys[RecordKeys.ClipboardItemContent.data.rawValue] = data as NSData
        }
        
        return keys
    }
}

// MARK: - ClipboardItemContent Extensions
extension ClipboardItemContent {
    init(managedObject: ClipboardItemContentMO) {
        self.id = managedObject.id ?? ""
        self.clipboardItemId = managedObject.clipboardItemId ?? ""
        self.typeIdentifier = managedObject.typeIdentifier ?? ""
        self.data = managedObject.data ?? Data()
        self.timestamp = managedObject.timestamp ?? Date()
        self.updatedDate = managedObject.updatedDate ?? Date()
        self.isRemoved = managedObject.isRemoved
        self.cloudKitRecordID = managedObject.cloudKitRecordID
    }
    
    func recordLegacy() -> CKRecord {
        CKRecord(self)
    }
    
    var record: CKRecord { recordLegacy() }
    
    init?(from record: CKRecord) {
        guard
            let id = record[RecordKeys.ClipboardItemContent.id] as? String,
            let clipboardItemId = record[RecordKeys.ClipboardItemContent.clipboardItemId] as? String,
            let typeIdentifier = record[RecordKeys.ClipboardItemContent.typeIdentifier] as? String,
            let data = record[RecordKeys.ClipboardItemContent.data] as? Data,
            let timestamp = record[RecordKeys.ClipboardItemContent.timestamp] as? Date,
            let updatedDate = record[RecordKeys.ClipboardItemContent.updatedDate] as? Date,
            let isRemoved = record[RecordKeys.ClipboardItemContent.isRemoved] as? Bool
        else { return nil }
        
        self.id = id
        self.clipboardItemId = clipboardItemId
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.cloudKitRecordID = record.recordID.recordName
    }
}

extension ClipboardItemContent: Syncable {

    init(record: CKRecord) throws {
        self.id = record.recordID.recordName
        self.ckData = record.encodedSystemFields
        
        guard
            let clipboardItemId = record[RecordKeys.ClipboardItemContent.clipboardItemId] as? String,
            let data = record[RecordKeys.ClipboardItemContent.data] as? Data,
            let typeIdentifier = record[RecordKeys.ClipboardItemContent.typeIdentifier] as? String,
            let timestamp = record[RecordKeys.ClipboardItemContent.timestamp] as? Date,
            let updatedDate = record[RecordKeys.ClipboardItemContent.updatedDate] as? Date,
            let isRemoved = record[RecordKeys.ClipboardItemContent.isRemoved] as? Bool
        else {
            throw NSError(domain: "ClipboardItemContent", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid record data"])
        }
        
        self.clipboardItemId = clipboardItemId
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.cloudKitRecordID = record.recordID.recordName
    }
    
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        guard
            let clientDate = clientRecord[RecordKeys.ClipboardItemContent.updatedDate] as? Date,
            let serverDate = serverRecord[RecordKeys.ClipboardItemContent.updatedDate] as? Date
        else {
            return serverRecord
        }
        
        return clientDate > serverDate ? clientRecord : serverRecord
    }
}
