//
//  CKRecord+Extensions.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 06.11.24.
//

import CloudKit

/// CloudKit Record Extensions
/// This file provides a type-safe wrapper for working with CloudKit records.
///
/// # Basic Usage
/// ```swift
/// // 1. Define your model conforming to CloudKitRecord
/// struct Recipe: CloudKitRecord {
///     let title: String
///     let ingredients: [String]
///     
///     static var recordType: String { "Recipe" }
///     
///     var recordKeys: [String: CKRecordValue] {
///         [
///             RecordKeys.Recipe.title.rawValue: title as NSString,
///             RecordKeys.Recipe.ingredients.rawValue: ingredients as NSArray
///         ]
///     }
/// }
///
/// // 2. Define your record keys
/// extension RecordKeys {
///     struct Recipe {
///         static var title: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "title") }
///         static var ingredients: RecordKeyPath<NSArray> { RecordKeyPath(rawValue: "ingredients") }
///     }
/// }
///
/// // 3. Use the model
/// // Create a record from your model
/// let recipe = Recipe(title: "Pasta", ingredients: ["Tomatoes", "Basil"])
/// let record = recipe.record()
///
/// // Create a model from a record
/// if let recipe = Recipe(from: record) {
///     print(recipe.title)
/// }
///
/// // Manual record manipulation
/// let record = CKRecord(recordType: Recipe.recordType)
/// record[RecordKeys.Recipe.title] = "Pasta" as NSString
/// record[.ingredients] = ["Tomatoes", "Basil"] as NSArray
/// ```
///
/// # Features
/// - Type-safe record keys
/// - Automatic conversion between Swift types and CloudKit types
/// - Easy model-to-record and record-to-model conversion
/// - Support for all CloudKit value types
///
/// # Best Practices
/// 1. Always define your record keys in the RecordKeys namespace
/// 2. Use the CloudKitRecord protocol for all your CloudKit-synced models
/// 3. Remember that CloudKit requires NSObject-compatible types
///
/// # Note
/// Remember to cast Swift types to their NS counterparts:
/// - String → NSString
/// - [String] → NSArray
/// - Int → NSNumber
/// - Data → NSData
/// - Date → NSDate
///

// MARK: - Record Key Path
@dynamicMemberLookup
struct RecordKeyPath<T: CKRecordValue> {
    let rawValue: String
    
    subscript<U>(dynamicMember keyPath: KeyPath<T, U>) -> U where U: CKRecordValue {
        fatalError("This is just for dynamic member lookup support")
    }
}

// MARK: - Record Type
protocol CloudKitRecord {
    static var recordType: String { get }
    var recordKeys: [String: CKRecordValue] { get }
}

// MARK: - CKRecord Extensions
extension CKRecord {
    subscript<T: CKRecordValue>(key: RecordKeyPath<T>) -> T? {
        get { self[key.rawValue] as? T }
        set { self[key.rawValue] = newValue }
    }
    
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    
    convenience init<T: CloudKitRecord>(_ record: T) {
        self.init(recordType: T.recordType)
        record.recordKeys.forEach { self[$0] = $1 }
    }
}

// MARK: - CKAsset Extensions
extension CKAsset {
    var data: Data? {
        guard let url = fileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Record Keys
struct RecordKeys {
    struct User {
        static var id: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "id") }
        static var name: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "name") }
    }
    
    // Add more record type namespaces as needed
    // struct Recipe { ... }
    // struct Comment { ... }
}

// MARK: - User Model
struct User: CloudKitRecord {
    let id: String
    let name: String
    
    static var recordType: String { "User" }
    
    var recordKeys: [String: CKRecordValue] {
        [
            RecordKeys.User.id.rawValue: id as NSString,
            RecordKeys.User.name.rawValue: name as NSString
        ]
    }
}

// MARK: - CloudKit Record Creation
extension User {
    func record() -> CKRecord {
        CKRecord(self)
    }
    
    init?(from record: CKRecord) {
        guard
            let id = record[RecordKeys.User.id] as? String,
            let name = record[RecordKeys.User.name] as? String
        else { return nil }
        
        self.id = id
        self.name = name
    }
}


