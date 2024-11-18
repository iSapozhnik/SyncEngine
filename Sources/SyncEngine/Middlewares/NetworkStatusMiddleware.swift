import Foundation
import Network
import os.log

protocol NetworkStatusMiddlewareProtocol {
    var isNetworkAvailable: Bool { get }
    func stopMonitoring()
}

final class NetworkStatusMiddleware: NetworkStatusMiddlewareProtocol {
    private(set) var isNetworkAvailable: Bool
    
    private let monitor: NWPathMonitor
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "NetworkStatusMiddleware")
    
    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        isNetworkAvailable = monitor.currentPath.status == .satisfied
    }
    
    deinit {
        stopMonitoring()
    }
    
    func stopMonitoring() {
        os_log("🛜 Stopping network monitor", log: log, type: .debug)
        monitor.cancel()
    }
    
    func networkPathUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let isAvailable = path.status == .satisfied
                guard isAvailable != self.isNetworkAvailable else { return }
                self.isNetworkAvailable = isAvailable
                
                os_log("🛜 Network status changed: %{public}@ at %{public}@",
                      log: log,
                      type: .debug,
                      isAvailable ? "available" : "unavailable",
                       Date().formatted(date: .omitted, time: .shortened)
                )
                
                continuation.yield(isAvailable)
            }
            
            monitor.start(queue: DispatchQueue(label: Constants.monitorQueue, qos: .utility))
            
            continuation.onTermination = { [weak self] _ in
                self?.monitor.cancel()
            }
        }
    }
}

// MARK: - Constants

private extension NetworkStatusMiddleware {
    enum Constants {
        static let monitorQueue = "com.networkstatus.monitor.queue"
    }
}
