import Cocoa

actor ClipboardObserver {
    private var continuation: AsyncStream<NSPasteboardItem>.Continuation?
    
    func startObserving() -> AsyncStream<NSPasteboardItem> {
        return AsyncStream { continuation in
            self.continuation = continuation
            
            Task {
                let pasteboard = NSPasteboard.general
                var changeCount = pasteboard.changeCount
                
                while !Task.isCancelled {
                    let newChangeCount = pasteboard.changeCount
                    if newChangeCount != changeCount {
                        changeCount = newChangeCount
                        
                        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
                            continuation.yield(pasteboardItem)
                        }
                    }
                    
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                }
            }
        }
    }
} 
