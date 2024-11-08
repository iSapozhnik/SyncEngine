//
//  ClipboardItemContent.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 08.11.24.
//

import Foundation

struct ClipboardItemContent {
    var ckData: Data? = nil
    let id: String
    let clipboardItemId: String
    let typeIdentifier: String
    let data: Data
    let timestamp: Date
    let updatedDate: Date
//    let isRemoved: Bool
    let cloudKitRecordID: String?
}
