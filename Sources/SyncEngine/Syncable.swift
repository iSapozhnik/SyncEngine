import CloudKit

public protocol Syncable: Identifiable {
    var id: String { get }
    var ckData: Data? { get set }
    
    /// The CloudKit record type for this model
    static var recordType: String { get }
    /// Convert the model to a CloudKit record
    func record(withZoneID zoneID: CKRecordZone.ID) -> CKRecord
    
    /// Create an instance from a CloudKit record
    init(record: CKRecord, configure: ((inout Self) -> Void)?) throws
    
    /// Resolve conflicts between server and local records
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord
}

extension Syncable {
    init(record: CKRecord, configure: ((inout Self) -> Void)? = nil) throws {
        try self.init(record: record, configure: configure)
    }
}

// Default implementation for common CloudKit record conversion
extension Syncable {
    public static var recordType: String {
        String(describing: Self.self)
    }
    
    public func recordID(withZoneID zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }
}
