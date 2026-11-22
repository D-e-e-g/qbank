import Foundation

/// Where a bank's file lives and how its folder is marked.
///
/// A free user's bank is the only copy of it, so it is kept in the device's own backup and
/// protected until the first unlock after a restart, the class the rest of QBankKit's files use so
/// a background send can still read them. It lives in a folder of its own that signing out never
/// touches (`Banks/<key>/`, beside the per-account `Accounts/` that sign-out erases).
enum StoreFiles {
    static let fileName = "bank.sqlite"
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// A key is the person's identifier from the identity provider or the server: letters, digits,
    /// dot, underscore and dash, not starting with a dot, so it can only name one folder.
    static func validate(key: String) throws(StoreError) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...128).contains(key.count), key.first != ".", key.allSatisfy(allowed.contains) else {
            throw .invalidKey(key)
        }
    }

    /// `<root>/Banks/<key>`, where `root` is `Application Support/QBankKit` in the app.
    static func directory(forKey key: String, in root: URL) throws(StoreError) -> URL {
        try validate(key: key)
        return root.appendingPathComponent("Banks", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    /// Makes the folder if it is missing and sets the marks on it and on the file when it exists.
    static func prepare(directory: URL) throws(StoreError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try mark(directory)
        } catch {
            throw .storage(operation: "prepare the bank folder", reason: error.localizedDescription)
        }
    }

    /// Marks the bank file and the files SQLite keeps beside it while a transaction runs, which
    /// are made after the folder and so are marked here once they exist.
    static func markFiles(at file: URL) throws(StoreError) {
        let siblings = ["", "-journal", "-wal", "-shm"].map { URL(fileURLWithPath: file.path + $0) }
        do {
            for url in siblings where FileManager.default.fileExists(atPath: url.path) { try mark(url) }
        } catch {
            throw .storage(operation: "protect the bank file", reason: error.localizedDescription)
        }
    }

    private static func mark(_ item: URL) throws {
        // Keeps the bank in the device backup and under data protection. A new file in a protected
        // folder takes the folder's class, and the file is set again so one made earlier is too.
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var url = item
        try url.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: item.path)
    }
}
