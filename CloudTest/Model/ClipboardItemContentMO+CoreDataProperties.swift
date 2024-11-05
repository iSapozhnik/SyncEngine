//
//  ClipboardItemContentMO+CoreDataProperties.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//
//

import Foundation
import CoreData


extension ClipboardItemContentMO {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ClipboardItemContentMO> {
        return NSFetchRequest<ClipboardItemContentMO>(entityName: "ClipboardItemContentMO")
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

extension ClipboardItemContentMO : Identifiable {

}
