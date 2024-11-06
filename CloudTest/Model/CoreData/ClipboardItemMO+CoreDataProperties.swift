//
//  ClipboardItemMO+CoreDataProperties.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 06.11.24.
//
//

import Foundation
import CoreData


extension ClipboardItemMO {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ClipboardItemMO> {
        return NSFetchRequest<ClipboardItemMO>(entityName: "ClipboardItemMO")
    }

    @NSManaged public var cloudKitRecordID: String?
    @NSManaged public var id: String?
    @NSManaged public var isRemoved: Bool
    @NSManaged public var updatedDate: Date?
    @NSManaged public var timestamp: Date?
    @NSManaged public var typeIdentifiers: String?

}

extension ClipboardItemMO : Identifiable {

}
