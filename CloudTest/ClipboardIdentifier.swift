//
//  ClipboardIdentifier.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//

import Foundation
import Cocoa
import CryptoKit

class ClipboardIdentifier {
    static func generateUniqueIdentifier(_ pasteboard: NSPasteboardItem) -> String? {
        // Get all available types for this item
        let types = pasteboard.types
        
        var contentToHash = ""
        
        // Process different types of content
        for type in types {
            switch type {
            case .string:
                if let string = pasteboard.string(forType: .string) {
                    contentToHash += "string:" + string
                }
                
            case .fileURL:
                if let url = pasteboard.propertyList(forType: .fileURL) as? String {
                    // For files, combine modification date with path for uniqueness
                    if let fileURL = URL(string: url) {
                        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                        let modDate = attributes?[.modificationDate] as? Date
                        contentToHash += "file:" + fileURL.path + ":" + (modDate?.description ?? "")
                    }
                }
                
            case .tiff, .png:
                if let imageData = pasteboard.data(forType: type) {
                    contentToHash += type.rawValue + ":" + String(imageData.count) + ":" + imageData.base64EncodedString()
                }
                
            case .rtf, .rtfd:
                if let rtfData = pasteboard.data(forType: type) {
                    contentToHash += type.rawValue + ":" + rtfData.base64EncodedString()
                }
                
            default:
                // For other types, try to get data representation
                if let data = pasteboard.data(forType: type) {
                    contentToHash += type.rawValue + ":" + String(data.count)
                }
            }
        }
        
        // Generate SHA256 hash of the combined content
        if !contentToHash.isEmpty {
            let inputData = Data(contentToHash.utf8)
            let hashed = SHA256.hash(data: inputData)
            return hashed.compactMap { String(format: "%02x", $0) }.joined()
        }
        
        return nil
    }
    
    // Helper method to check if content already exists
    static func isContentDuplicate(forPasteboardItem pasteboard: NSPasteboardItem, existingHashes: Set<String>) -> Bool {
        guard let newHash = generateUniqueIdentifier(pasteboard) else { return false }
        return existingHashes.contains(newHash)
    }
}
