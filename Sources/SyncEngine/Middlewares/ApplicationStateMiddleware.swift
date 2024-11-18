import Foundation
import os.log
import AppKit

enum ApplicationState {
    case active
    case inactive
}

protocol ApplicationStateMiddlewareProtocol {
    var applicationState: AsyncStream<ApplicationState> { get }
    var isActive: Bool { get }
}

final class ApplicationStateMiddleware: ApplicationStateMiddlewareProtocol {
    let applicationState: AsyncStream<ApplicationState>
    private let continuation: AsyncStream<ApplicationState>.Continuation
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "ApplicationStateMiddleware")
    
    private(set) var isActive: Bool
    
    init() {
        let application = NSApplication.shared
        self.isActive = application.isActive
        (applicationState, continuation) = AsyncStream<ApplicationState>.makeStream()
        
        setupObservers()
    }
    
    deinit {
        removeObservers()
        continuation.finish()
    }
    
    private func setupObservers() {
        let notificationCenter = NotificationCenter.default
        
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        
        os_log("📱 Application state observers setup", log: log, type: .debug)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        os_log("📱 Application state observers removed", log: log, type: .debug)
    }
    
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        isActive = true
        continuation.yield(.active)
    }
    
    @objc private func applicationWillResignActive(_ notification: Notification) {
        isActive = false
        continuation.yield(.inactive)
    }
} 
