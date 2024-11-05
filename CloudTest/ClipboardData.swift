import AppKit

struct ClipboardData: Sendable {
    let identifier: String
    let types: [NSPasteboard.PasteboardType]
    let contents: [NSPasteboard.PasteboardType: Data]
    let timestamp: Date
    
    init(from pasteboardItem: NSPasteboardItem) {
        let identifier = ClipboardIdentifier.generateUniqueIdentifier(pasteboardItem)
        
        self.identifier = identifier
        self.types = pasteboardItem.types
        self.timestamp = Date()
        
        var contents: [NSPasteboard.PasteboardType: Data] = [:]
        for type in types {
            if let data = pasteboardItem.data(forType: type) {
                contents[type] = data
            }
        }
        self.contents = contents
    }
} 
