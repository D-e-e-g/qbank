import Foundation
import Testing

@testable import QBankKit

/// The bank's own export: the archive written at the bank's clock, from one read, with the bank
/// unchanged. Invented data only.
@Suite struct BankExportTests {
    @Test func theBankWritesItsArchiveAtItsClockAndIsLeftAsItWas() async throws {
        let world = try await ArchiveWorld.make()
        let bank = LocalBank(store: world.store, clock: { ArchiveWorld.date })
        let before = try ArchiveWorld.dump(world.store)
        let counts = try BankArchive.counts(of: world.store)

        let archive = try bank.exportArchive()

        #expect(archive == (try BankArchive.write(from: world.store, at: ArchiveWorld.date)))
        #expect(try ArchiveWorld.dump(world.store) == before)
        #expect(try BankArchive.counts(of: world.store) == counts)
        let fresh = try ArchiveWorld.empty()
        #expect(try BankArchive.read(archive, into: fresh) == counts)
    }
}
