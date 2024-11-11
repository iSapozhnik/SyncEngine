//
//  SyncTaskTracker.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 10.11.24.
//

import Foundation

final actor SyncTaskTracker {
    private var activeTasks: Set<Task<Void, Never>> = []
    
    func track(_ task: Task<Void, Never>) {
        activeTasks.insert(task)
    }
    
    func remove(_ task: Task<Void, Never>) {
        activeTasks.remove(task)
    }
    
    func cancelAll() {
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
    }
}
