//
//  ClipboardItemMO+CoreDataProperties.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//
//

import Foundation
import CoreData


extension ClipboardItemMO {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ClipboardItemMO> {
        return NSFetchRequest<ClipboardItemMO>(entityName: "ClipboardItemMO")
    }

    @NSManaged public var id: String?
    @NSManaged public var timestamp: Date?
    @NSManaged public var cloudKitRecordID: String?
    @NSManaged public var modificationDate: Date?
    @NSManaged public var isRemoved: Bool
    @NSManaged public var typeIdentifiers: String?

}

extension ClipboardItemMO : Identifiable {

}
