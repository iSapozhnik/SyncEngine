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
            await setupObservers()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        os_log("☁️ Account status observers removed", log: log, type: .debug)
        continuation.finish()
    }
    
    // MARK: - Public Methods
    
    func refreshStatus() async {
        await checkAccountStatus()
    }

    // MARK: - Private Methods
    
    private func setupObservers() async {
        os_log("☁️ Account status observers setup", log: log, type: .debug)
        let accountChangedStream = NotificationCenter.default.notifications(named: .CKAccountChanged, object: container).map { _ in ()}
        for await _ in accountChangedStream {
            await checkAccountStatus()
        }
    }

    private func removeObservers() {
        
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
