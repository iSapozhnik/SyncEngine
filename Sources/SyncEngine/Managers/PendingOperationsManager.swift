import Foundation
import os.log

final class PendingOperationsManager {
    enum Operation: Codable {
        case deletion(recordIDs: [String])
    }
    
    private let log = OSLog(subsystem: SyncEngine.Constants.subsystemName, category: "PendingOperationsManager")
    private let fileManager: FileManager
    private let operationsFileURL: URL
    
    private var pendingOperations: [Operation] = []
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pendingOperationsDirectory = applicationSupport.appendingPathComponent("PendingOperations", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: pendingOperationsDirectory, withIntermediateDirectories: true)
        
        operationsFileURL = pendingOperationsDirectory.appendingPathComponent("pending_operations.json")
        os_log("Created pending operations files at: %{public}@", log: log, type: .debug, operationsFileURL.absoluteString)

        loadOperations()
    }
    
    func addPendingDeletions(recordIDs: [String]) {
        pendingOperations.append(.deletion(recordIDs: recordIDs))
        saveOperations()
        os_log("Added pending deletion for records: %{public}@", log: log, type: .debug, recordIDs)
    }
    
    func getPendingDeletions() -> [String] {
        let result = pendingOperations.compactMap { operation in
            if case .deletion(let recordIDs) = operation {
                return recordIDs
            }
            return nil
        }.flatMap { $0 }
        
        return result
    }
    
    func removePendingDeletions(recordIDs: [String]) {
        pendingOperations.removeAll { operation in
            if case .deletion(let pendingRecordIDs) = operation {
                return pendingRecordIDs.contains { recordIDs.contains($0) }
            }
            return false
        }
        saveOperations()
        os_log("Removed pending deletions for records: %{public}@",
               log: log,
               type: .debug,
               recordIDs.joined(separator: ", "))
    }
    
    private func saveOperations() {
        do {
            let data = try JSONEncoder().encode(pendingOperations)
            try data.write(to: operationsFileURL)
        } catch {
            os_log("Failed to save pending operations: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }
    
    private func loadOperations() {
        guard fileManager.fileExists(atPath: operationsFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: operationsFileURL)
            pendingOperations = try JSONDecoder().decode([Operation].self, from: data)
        } catch {
            os_log("Failed to load pending operations: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }
} 
