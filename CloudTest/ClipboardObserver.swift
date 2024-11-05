import Cocoa

actor ClipboardObserver {
    private var continuation: AsyncStream<ClipboardData>.Continuation?
    
    func startObserving() -> AsyncStream<ClipboardData> {
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
                            let clipboardData = ClipboardData(from: pasteboardItem)
                            continuation.yield(clipboardData)
                        }
                    }
                    
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                }
            }
        }
    }
} 
