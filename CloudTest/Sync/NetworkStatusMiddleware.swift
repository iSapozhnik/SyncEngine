//
//  NEtworkStatusMiddleware.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 14.11.24.
//

import Foundation
import Network
import os.log

protocol NetworkStatusMiddlewareProtocol {
    var networkStatus: AsyncStream<Bool> { get }
    var isNetworkAvailable: Bool { get }
    func startMonitoring()
    func stopMonitoring()
}

final class NetworkStatusMiddleware: NetworkStatusMiddlewareProtocol {
    // MARK: - Public properties
    
    let networkStatus: AsyncStream<Bool>
    private(set) var isNetworkAvailable: Bool
    
    // MARK: - Private properties
    
    private let monitor = NWPathMonitor()
    private let continuation: AsyncStream<Bool>.Continuation
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName,
                          category: "NetworkStatusMiddleware")
    private var monitoringTask: Task<Void, Never>?
    
    // MARK: - Lifecycle
    
    init() {
        isNetworkAvailable = NWPathMonitor().currentPath.status == .satisfied

        (networkStatus, continuation) = AsyncStream<Bool>.makeStream()
    }
    
    deinit {
        stopMonitoring()
        continuation.finish()
    }
    
    // MARK: - Public methods
    
    func startMonitoring() {
        os_log("🛜 Starting network monitor", log: log, type: .debug)
        
        monitoringTask = Task {
            for await path in networkPathUpdates() {
                guard !Task.isCancelled else { break }
                
                let isAvailable = path.status == .satisfied
                if isNetworkAvailable != isAvailable {
                    isNetworkAvailable = isAvailable
                    continuation.yield(isAvailable)
                    
                    os_log("🛜 Network status changed: %{public}@",
                          log: log,
                          type: .debug,
                          isAvailable ? "available" : "unavailable")
                }
            }
        }
    }
    
    func stopMonitoring() {
        os_log("🛜 Stopping network monitor", log: log, type: .debug)
        monitoringTask?.cancel()
        monitor.cancel()
    }
    
    // MARK: - Private methods
    
    private func networkPathUpdates() -> AsyncStream<NWPath> {
        AsyncStream { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            
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
