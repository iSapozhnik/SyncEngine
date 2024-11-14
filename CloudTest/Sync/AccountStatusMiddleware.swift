//
//  AccountStatusMiddleware.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 14.11.24.
//

import Foundation
import CloudKit
import os.log

protocol AccountStatusMiddlewareProtocol {
    var accountStatus: AsyncStream<CKAccountStatus> { get }
    func refreshStatus() async
}

final class AccountStatusMiddleware: AccountStatusMiddlewareProtocol {
    let accountStatus: AsyncStream<CKAccountStatus>
    private let container: CKContainer
    private let continuation: AsyncStream<CKAccountStatus>.Continuation
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "AccountStatusMiddleware")
    private(set) var lastKnownStatus: CKAccountStatus?

    init(container: CKContainer) {
        self.container = container
        (accountStatus, continuation) = AsyncStream<CKAccountStatus>.makeStream()

        Task {
            await checkAccountStatus()
        }

        setupObservers()
    }

    deinit {
        removeObservers()
        continuation.finish()
    }
    
    // MARK: - Public Methods
    
    func refreshStatus() async {
        await checkAccountStatus()
    }

    // MARK: - Private Methods
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccountChange),
            name: .CKAccountChanged,
            object: container 
        )
        os_log("☁️ Account status observers setup", log: log, type: .debug)
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        os_log("☁️ Account status observers removed", log: log, type: .debug)
    }

    @objc private func handleAccountChange() {
        Task {
            await checkAccountStatus()
        }
    }
    
    private func checkAccountStatus(retries: Int = 3) async {
        guard retries > 0 else {
            os_log("☁️ Max retry count exceeded while checking account status", log: log, type: .error)
            return
        }
        
        do {
            let status = try await container.accountStatus()
            
            // Only notify if status has changed
            if lastKnownStatus != status {
                os_log("☁️ Account status changed from %{public}@ to %{public}@",
                       log: log,
                       type: .debug, 
                       lastKnownStatus?.description ?? "Unknown",
                       status.description)
                
                lastKnownStatus = status
                continuation.yield(status)
            }
        } catch {
            os_log("☁️ Failed to get account status: %{public}@", log: log, type: .error, error.localizedDescription)
            
            if await error.retryCloudKitOperationIfPossible(log) {
                await checkAccountStatus(retries: retries - 1)
            }
        }
    }
}

// MARK: - Constants
private extension AccountStatusMiddleware {
    enum Constants {
        static let maxRetries = 3
    }
}
