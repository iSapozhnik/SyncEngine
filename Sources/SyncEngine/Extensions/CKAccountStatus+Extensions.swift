import Foundation
import CloudKit

extension CKAccountStatus {
    var description: String {
        switch self {
        case .available:
            return "Available"
        case .noAccount:
            return "No iCloud Account"
        case .restricted:
            return "Restricted"
        case .couldNotDetermine:
            return "Could Not Determine"
        case .temporarilyUnavailable:
            return "Temporarily Unavailable"
        @unknown default:
            return "Unknown Status"
        }
    }
    
    var detailedDescription: String {
        switch self {
        case .available:
            return "iCloud account is available and ready to use"
        case .noAccount:
            return "No iCloud account found. Please sign in to use iCloud features"
        case .restricted:
            return "iCloud access is restricted. Please check your settings"
        case .couldNotDetermine:
            return "Could not determine iCloud account status. Please try again"
        case .temporarilyUnavailable:
            return "iCloud account is temporarily unavailable. Please try again later"
        @unknown default:
            return "Unknown iCloud account status"
        }
    }
}
