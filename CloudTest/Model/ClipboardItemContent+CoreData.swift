//
//  ClipboardItemContent+CoreData.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 08.11.24.
//

import Foundation

extension ClipboardItemContent {
    init(managedObject: ClipboardItemContentMO) {
        self.id = managedObject.id ?? ""
        self.clipboardItemId = managedObject.clipboardItemId ?? ""
        self.typeIdentifier = managedObject.typeIdentifier ?? ""
        self.data = managedObject.data ?? Data()
        self.timestamp = managedObject.timestamp ?? Date()
        self.updatedDate = managedObject.updatedDate ?? Date()
        self.cloudKitRecordID = managedObject.cloudKitRecordID
    }
}
