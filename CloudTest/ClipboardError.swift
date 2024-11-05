//
//  ClipboardError.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//

import Foundation

enum ClipboardError: LocalizedError {
    case saveFailed(Error)
    case fetchFailed(Error)
    case itemNotFound
    case invalidPasteboardContent
    case contextError
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let error): return "Failed to save clipboard: \(error.localizedDescription)"
        case .fetchFailed(let error): return "Failed to fetch clipboard data: \(error.localizedDescription)"
        case .itemNotFound: return "Clipboard item not found"
        case .invalidPasteboardContent: return "Invalid pasteboard content"
        case .contextError: return "Core Data context error"
        }
    }
}
