import Foundation
import Synchronization

/// A name for one cached value, typed by what it holds, so a read always gets back what was stored.
public struct CacheKey<Value: Codable & Sendable>: Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

extension CacheKey where Value == Catalog {
    /// Home's semesters, courses and study topics. The name is the one it had when it held the
    /// semesters alone, so a copy saved then is still read.
    public static var catalog: CacheKey { CacheKey("semesters") }
}

extension CacheKey where Value == CourseDetail {
    public static func course(_ id: String) -> CacheKey { CacheKey("course-\(id)") }
}

extension CacheKey where Value == PracticeSet {
    public static func practiceSet(_ id: String) -> CacheKey { CacheKey("practice-set-\(id)") }
}

extension CacheKey where Value == [Term] {
    public static func terms(courseID: String) -> CacheKey { CacheKey("terms-\(courseID)") }
}

extension CacheKey where Value == ReviewList {
    public static func review(courseID: String) -> CacheKey { CacheKey("review-\(courseID)") }
}

/// A cached value and when it was saved, for the "Saved 7:40" badge.
public struct Cached<Value: Sendable>: Sendable {
    public let value: Value
    public let savedAt: Date
}

extension Cached: Equatable where Value: Equatable {}

/// One cached value as the "Saved for offline" screen lists it.
public struct CacheEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let savedAt: Date
    public let byteCount: Int

    public var id: String { name }
}

/// Courses, sets, and questions she has loaded, kept so she can study without signal.
/// The cache never decides what is current: the app shows what it has, then refreshes when online.
public protocol ContentCache: Sendable {
    func value<Value>(for key: CacheKey<Value>) async throws(StorageError) -> Cached<Value>?
    func store<Value>(_ value: Value, for key: CacheKey<Value>, savedAt: Date) async throws(StorageError)
    func remove(named name: String) async throws(StorageError)
    func entries() async throws(StorageError) -> [CacheEntry]
    func removeAll() async throws(StorageError)
}

extension ContentCache {
    public func store<Value>(_ value: Value, for key: CacheKey<Value>) async throws(StorageError) {
        try await store(value, for: key, savedAt: Date())
    }

    public func remove<Value>(_ key: CacheKey<Value>) async throws(StorageError) {
        try await remove(named: key.name)
    }
}

/// The cache as one JSON file per value in a directory, kept out of backups: the server has it all.
public struct FileContentCache: ContentCache {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/QBankKit/Content`.
    public static func standard() throws(StorageError) -> FileContentCache {
        FileContentCache(directory: try FileLocations.applicationSupport().appendingPathComponent("Content", isDirectory: true))
    }

    public func value<Value>(for key: CacheKey<Value>) async throws(StorageError) -> Cached<Value>? {
        guard let data = try FileLocations.read(fileURL(for: key.name), operation: "read saved \(key.name)") else { return nil }
        do {
            let envelope = try QBankJSON.decoder.decode(Envelope<Value>.self, from: data)
            return Cached(value: envelope.value, savedAt: envelope.savedAt)
        } catch {
            // Saved by an older version in a shape this one cannot read: treat it as not saved.
            return nil
        }
    }

    public func store<Value>(_ value: Value, for key: CacheKey<Value>, savedAt: Date) async throws(StorageError) {
        try FileLocations.ensureDirectory(directory, excludedFromBackup: true)
        let data: Data
        do {
            data = try QBankJSON.encoder.encode(Envelope(name: key.name, savedAt: savedAt, value: value))
        } catch {
            throw StorageError(operation: "save \(key.name)", reason: "\(error)")
        }
        try FileLocations.write(data, to: fileURL(for: key.name), operation: "save \(key.name)")
    }

    public func remove(named name: String) async throws(StorageError) {
        do {
            try FileManager.default.removeItem(at: fileURL(for: name))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw StorageError(operation: "remove \(name)", reason: error.localizedDescription)
        }
    }

    public func entries() async throws(StorageError) -> [CacheEntry] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw StorageError(operation: "list saved content", reason: error.localizedDescription)
        }
        var entries: [CacheEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try FileLocations.read(file, operation: "read \(file.lastPathComponent)"),
                let header = try? QBankJSON.decoder.decode(Header.self, from: data)
            else { continue }
            entries.append(CacheEntry(name: header.name, savedAt: header.savedAt, byteCount: data.count))
        }
        return entries.sorted { $0.name < $1.name }
    }

    public func removeAll() async throws(StorageError) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw StorageError(operation: "remove saved content", reason: error.localizedDescription)
        }
    }

    /// Names are built from server ids; anything outside a safe file name is replaced.
    private func fileURL(for name: String) -> URL {
        let safe = String(
            name.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_" ? Character(scalar) : "_"
            })
        return directory.appendingPathComponent("\(safe).json")
    }

    private struct Envelope<Value: Codable>: Codable {
        let name: String
        let savedAt: Date
        let value: Value
    }

    private struct Header: Decodable {
        let name: String
        let savedAt: Date
    }
}

/// The cache in memory, for tests and previews.
public final class InMemoryContentCache: ContentCache {
    private struct Item {
        let value: any Sendable
        let savedAt: Date
        let byteCount: Int
    }

    private let items = Mutex<[String: Item]>([:])

    public init() {}

    public func value<Value>(for key: CacheKey<Value>) async throws(StorageError) -> Cached<Value>? {
        items.withLock { items in
            guard let item = items[key.name], let value = item.value as? Value else { return nil }
            return Cached(value: value, savedAt: item.savedAt)
        }
    }

    public func store<Value>(_ value: Value, for key: CacheKey<Value>, savedAt: Date) async throws(StorageError) {
        let byteCount = (try? QBankJSON.encoder.encode(value).count) ?? 0
        items.withLock { $0[key.name] = Item(value: value, savedAt: savedAt, byteCount: byteCount) }
    }

    public func remove(named name: String) async throws(StorageError) {
        _ = items.withLock { $0.removeValue(forKey: name) }
    }

    public func entries() async throws(StorageError) -> [CacheEntry] {
        items.withLock { items in
            items.map { CacheEntry(name: $0.key, savedAt: $0.value.savedAt, byteCount: $0.value.byteCount) }
                .sorted { $0.name < $1.name }
        }
    }

    public func removeAll() async throws(StorageError) {
        items.withLock { $0.removeAll() }
    }
}
