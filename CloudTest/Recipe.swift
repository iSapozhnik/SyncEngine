//struct Recipe: CloudKitModel {
//    let id: String
//    var ckData: Data?
//    // ... other properties ...
//    
//    static var recordType: String { "Recipe" }
//    
//    init(record: CKRecord) throws {
//        self.id = record.recordID.recordName
//        self.ckData = record.encodedSystemFields
//        // ... initialize other properties from record ...
//    }
//    
//    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
//        // Implement your conflict resolution logic here
//        // For example, you might want to keep the most recent version
//        return serverRecord
//    }
//} 
