//
//  ClipboardItem+CoreData.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 07.11.24.
//

import Foundation

extension ClipboardItem {

    // Prevent memberwise initializer
    fileprivate init() {
        fatalError("ClipboardItem should not be initialized directly")
    }
    
    fileprivate init(
        id: String,
        timestamp: Date,
        updatedDate: Date,
        isRemoved: Bool,
        cloudKitRecordID: String? = nil,
        contents: [ClipboardItemContent]
    ) {
        fatalError("ClipboardItem should not be initialized directly")
    }

    init(managedObject: ClipboardItemMO, contents: [ClipboardItemContentMO]) {
        let date = Date()
        self.id = managedObject.id ?? "No id"
        self.ckData = managedObject.ckData
        self.timestamp = managedObject.timestamp ?? date
        self.updatedDate = managedObject.updatedDate ?? date
        self.cloudKitRecordID = managedObject.cloudKitRecordID
        self.contents = contents.map { ClipboardItemContent(managedObject: $0) }
    }
}
