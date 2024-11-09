//
//  ClipboardItemMO+CoreDataProperties.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 09.11.24.
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
    @NSManaged public var timestamp: Date?
    @NSManaged public var typeIdentifiers: String?
    @NSManaged public var updatedDate: Date?
    @NSManaged public var ckData: Data?

}

extension ClipboardItemMO : Identifiable {

}
