import CloudKit

public protocol Syncable {
    var id: String { get }
    var ckData: Data? { get set }
    
    /// The CloudKit record type for this model
    static var recordType: String { get }
    /// Convert the model to a CloudKit record
    var record: CKRecord { get }
    func recordLegacy() -> CKRecord
    
    /// Create an instance from a CloudKit record
    init(record: CKRecord, configure: ((inout Self) throws -> Void)?) throws
    
    /// Resolve conflicts between server and local records
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord
}

extension Syncable {
    init(record: CKRecord, configure: ((inout Self) throws -> Void)? = nil) throws {
        try self.init(record: record, configure: nil)
    }
}

// Default implementation for common CloudKit record conversion
extension Syncable {
    static var recordType: String {
        String(describing: Self.self)
    }
}
