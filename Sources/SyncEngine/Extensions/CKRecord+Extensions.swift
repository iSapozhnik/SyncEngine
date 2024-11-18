import CloudKit

// MARK: - CKRecord Extensions

extension CKRecord {
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}

extension CKAsset {
    var data: Data? {
        guard let fileURL else { return nil }
        return try? Data(contentsOf: fileURL)
    }
}
