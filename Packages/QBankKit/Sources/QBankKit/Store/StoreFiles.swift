import Foundation

/// Where a bank's file lives and how its folder is marked.
///
/// A free user's bank is the only copy of it, so it is kept in the device's own backup and
/// protected until the first unlock after a restart, the class the rest of QBankKit's files use so
/// a background send can still read them. It lives in a folder of its own that signing out never
/// touches (`Banks/<key>/`, beside the per-account `Accounts/` that sign-out erases).
enum StoreFiles {
    /// The bank's first file. A bank that came back from QBank Cloud is in a fresh file beside it
    /// (`freshFileName(at:)`), and the bank's hand-over record names the one in use (`BankHandover`).
    static let fileName = LocalStore.firstFile
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    /// What SQLite may keep beside a bank file while a transaction runs, by suffix.
    static let sideFileSuffixes = ["-journal", "-wal", "-shm"]

    /// The name of a fresh file for a bank that comes back from QBank Cloud, dated to the
    /// millisecond in UTC, such as `bank-20261126T143705123Z.sqlite`.
    static func freshFileName(at date: Date) -> String {
        "bank-\(dated(date)).sqlite"
    }

    /// `date` to the millisecond in UTC, as a file name dates it: `20261126T143705123Z`.
    static func dated(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }

    /// A bank file's name is `bank.sqlite` or a fresh file's name, so it can only name a file in
    /// the bank's own folder.
    static func validate(fileName: String) throws(StoreError) {
        guard fileName == Self.fileName || isFreshFileName(fileName) else { throw .invalidFileName(fileName) }
    }

    private static func isFreshFileName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == "bank-20261126T143705123Z.sqlite".utf8.count, name.hasPrefix("bank-"), name.hasSuffix("Z.sqlite") else { return false }
        let stamp = bytes[5..<23]
        return stamp.enumerated().allSatisfy { index, byte in
            index == 8 ? byte == UInt8(ascii: "T") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    /// Takes away a bank file this phone began writing and never used, with what SQLite kept beside
    /// it. Only a hand-back that did not finish calls it, for the fresh file it made itself.
    static func removeUnused(_ file: URL) {
        for url in [file] + sideFileSuffixes.map({ URL(fileURLWithPath: file.path + $0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

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
        let siblings = ([""] + sideFileSuffixes).map { URL(fileURLWithPath: file.path + $0) }
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
