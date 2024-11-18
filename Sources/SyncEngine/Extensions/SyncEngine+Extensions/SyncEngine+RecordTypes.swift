import Foundation
import CloudKit

extension SyncEngine {
    func register<T: Syncable>(_ type: T.Type) {
        typeRegistry[T.recordType] = type
        initializerRegistry[T.recordType] = { record in
            try T(record: record, configure: nil)
        }
    }
    
    func getType(for recordType: String) -> (any Syncable.Type)? {
        return typeRegistry[recordType]
    }
    
    func createInstance(from record: CKRecord) throws -> (any Syncable)? {
        guard let initializer = initializerRegistry[record.recordType] else { return nil }
        return try initializer(record)
    }
}
