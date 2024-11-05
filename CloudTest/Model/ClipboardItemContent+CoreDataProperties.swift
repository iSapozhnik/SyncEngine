//
//  ClipboardItemContent+CoreDataProperties.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//
//

import Foundation
import CoreData


extension ClipboardItemContent {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ClipboardItemContent> {
        return NSFetchRequest<ClipboardItemContent>(entityName: "ClipboardItemContent")
    }

    @NSManaged public var cloudKitRecordID: String?
    @NSManaged public var id: String?
    @NSManaged public var isRemoved: Bool
    @NSManaged public var modificationDate: Date?
    @NSManaged public var timestamp: Date?
    @NSManaged public var typeIdentifier: String?
    @NSManaged public var data: Data?
    @NSManaged public var clipboardItemId: String?

}

extension ClipboardItemContent : Identifiable {

}
