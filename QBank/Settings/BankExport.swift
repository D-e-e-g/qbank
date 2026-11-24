import Foundation
import QBankKit

/// Export my bank: the whole bank as one bank archive file, so a person always holds a copy of their
/// own questions and progress. A bank on this phone is written from the phone; a bank on the server
/// is downloaded from it, and the file is the same either way. Neither changes the bank.
nonisolated enum BankExport {
    /// The file's name says what it is and the day it was made, in the phone's time zone.
    static func fileName(on date: Date, calendar: Calendar = .current) -> String {
        "qbank-bank-\(CalendarDay.text(from: date, calendar: calendar) ?? "export").json"
    }

    /// Writes `data` as the day's file in a folder of its own under `directory` and returns where it
    /// is. An earlier export is cleared first, so the phone keeps at most one copy waiting to be shared.
    static func write(_ data: Data, on date: Date, in directory: URL, calendar: Calendar = .current) throws -> URL {
        let folder = directory.appendingPathComponent("BankExport", isDirectory: true)
        let files = FileManager.default
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName(on: date, calendar: calendar))
        try data.write(to: file, options: .atomic)
        return file
    }
}

extension AppModel {
    /// The bank as a file ready for the share sheet: written from the phone for a free account, else
    /// downloaded from the server. Throws what the server or the file system answered.
    func exportBank(in directory: URL = FileManager.default.temporaryDirectory, now: Date = Date()) async throws -> URL {
        let data: Data
        if let bank {
            data = try bank.exportArchive()
        } else {
            data = try await client.downloadBank()
        }
        return try BankExport.write(data, on: now, in: directory)
    }
}
