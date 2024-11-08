import AppKit
import CloudKit

// MARK: - ClipboardItem
struct ClipboardItem {
    /// Used to store the encoded `CKRecord.ID` so that local records can be matched with
    /// records on the server. This ensures updates don't cause duplication of records.
    var ckData: Data? = nil
    let id: String
    let timestamp: Date
    let updatedDate: Date
    let cloudKitRecordID: String?
    let contents: [ClipboardItemContent]
}
