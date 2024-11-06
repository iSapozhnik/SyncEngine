import CloudKit

public protocol Syncable {
    var id: String { get }
    var ckData: Data? { get set }
    
    /// The CloudKit record type for this model
    static var recordType: String { get }
    /// Convert the model to a CloudKit record
    func record() -> CKRecord
    
    /// Create an instance from a CloudKit record
    init(record: CKRecord) throws
    
    /// Resolve conflicts between server and local records
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord
}

// Default implementation for common CloudKit record conversion
extension Syncable {
//    public var record: CKRecord {
//        let recordID = CKRecord.ID(recordName: id, zoneID: SyncConstants.customZoneID)
//        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
//        
//        // Use Mirror to automatically encode all properties
//        let mirror = Mirror(reflecting: self)
//        for child in mirror.children {
//            guard let label = child.label else { continue }
//            // Skip id and ckData as they're handled separately
//            guard label != "id" && label != "ckData" else { continue }
//            record[label] = child.value as? CKRecordValue
//        }
//        
//        return record
//    }
}
