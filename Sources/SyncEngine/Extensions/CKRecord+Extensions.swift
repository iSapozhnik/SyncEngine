import CloudKit

// MARK: - CKRecord Extensions

extension CKRecord {
    public var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}

extension CKAsset {
    public var data: Data? {
        guard let fileURL else { return nil }
        return try? Data(contentsOf: fileURL)
    }
}
