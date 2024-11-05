import AppKit

struct ClipboardItem: Sendable {
    let id: String
    let timestamp: Date
    let modificationDate: Date
    let isRemoved: Bool
    let cloudKitRecordID: String?
    let contents: [ClipboardItemContent]
    
    init(
        id: String,
        timestamp: Date,
        modificationDate: Date,
        isRemoved: Bool,
        cloudKitRecordID: String? = nil,
        contents: [ClipboardItemContent]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modificationDate = modificationDate
        self.isRemoved = isRemoved
        self.cloudKitRecordID = cloudKitRecordID
        self.contents = contents
    }
    
    init(managedObject: ClipboardItemMO) {
        self.id = managedObject.id ?? ""
        self.timestamp = managedObject.timestamp ?? Date()
        self.modificationDate = managedObject.modificationDate ?? Date()
        self.isRemoved = managedObject.isRemoved
        self.cloudKitRecordID = managedObject.cloudKitRecordID
        self.contents = [] // Will be populated separately
    }
}

struct ClipboardItemContent: Sendable {
    let id: String
    let clipboardItemId: String
    let typeIdentifier: String
    let data: Data
    let timestamp: Date
    let modificationDate: Date
    let isRemoved: Bool
    let cloudKitRecordID: String?
    
    init(managedObject: ClipboardItemContentMO) {
        self.id = managedObject.id ?? ""
        self.clipboardItemId = managedObject.clipboardItemId ?? ""
        self.typeIdentifier = managedObject.typeIdentifier ?? ""
        self.data = managedObject.data ?? Data()
        self.timestamp = managedObject.timestamp ?? Date()
        self.modificationDate = managedObject.modificationDate ?? Date()
        self.isRemoved = managedObject.isRemoved
        self.cloudKitRecordID = managedObject.cloudKitRecordID
    }
} 
