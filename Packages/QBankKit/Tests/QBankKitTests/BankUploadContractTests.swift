import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// `PUT /api/me/bank`, the upload of a whole bank, against the pinned server contract
/// (`Fixtures/openapi.json`): what the kit sends, that the counts it reads are the contract's twelve,
/// and that every refusal the contract names decodes with its code and its words. The answers are
/// shaped by the contract's `BankStored` and `BankError` schemas. Invented data only.
@Suite("Contract: the bank upload")
struct BankUploadContractTests {
    private static func spec() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private static func upload() throws -> JSONValue {
        try #require(try spec()["paths"]?["/api/me/bank"]?["put"])
    }

    private func client(_ cloud: CloudStandIn) -> QBankClient {
        QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
    }

    @Test func theUploadTakesABankArchiveAndAnswersTheTwelveCounts() throws {
        let spec = try Self.spec()
        let upload = try Self.upload()
        #expect(upload["requestBody"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue == "#/components/schemas/BankArchive")
        #expect(upload["responses"]?["200"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue == "#/components/schemas/BankStored")
        let stored = try #require(spec["components"]?["schemas"]?["BankStored"])
        #expect(stored["required"]?.arrayValue?.compactMap(\.stringValue) == ["counts"])
        #expect(stored["properties"]?["counts"]?["$ref"]?.stringValue == "#/components/schemas/BankCounts")
        let counts = try #require(spec["components"]?["schemas"]?["BankCounts"])
        #expect(Set(counts["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) == Set(BankArchive.tableKeys))
        guard case .object(let responses)? = upload["responses"] else {
            Issue.record("the upload documents no answers")
            return
        }
        #expect(Set(responses.keys) == ["200", "400", "401", "403", "409", "413", "503"])
    }

    @Test func theArchiveIsSentByteForByteWithTheSessionAndALongerWait() async throws {
        let world = try await ArchiveWorld.make()
        let archive = try BankArchive.write(from: world.store, at: ArchiveWorld.date)
        let cloud = CloudStandIn(.stores)

        let counts = try await client(cloud).uploadBank(archive)

        #expect(counts == (try BankArchive.counts(of: world.store)))
        let request = try #require(cloud.requests.first)
        #expect(cloud.requests.count == 1)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/api/me/bank")
        #expect(request.httpBody == archive)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        #expect(request.timeoutInterval == QBankClient.bankUploadTimeout)
    }

    /// Each refusal the contract documents for the upload, with the sentence the contract gives it
    /// where it gives one.
    @Test(arguments: [
        (400, "invalid_archive"), (401, "unauthenticated"), (403, "cloud_required"), (409, "bank_not_empty"), (409, "bank_ids_taken"),
        (413, "archive_too_large"),
    ])
    func everyRefusalTheContractNamesDecodesWithItsCodeAndWords(_ status: Int, _ code: String) async throws {
        let described = try #require(try Self.upload()["responses"]?[String(status)]?["description"]?.stringValue)
        #expect(described.contains(code) || code == "unauthenticated", "the contract names \(code) under \(status)")
        let message = code == "bank_not_empty" ? try Self.notEmptySentence(in: described) : "Nothing was changed."
        let cloud = CloudStandIn(.answers(status, #"{"error":"\#(code)","message":"\#(message)"}"#))

        await #expect(throws: QBankError.server(ServerError(status: status, code: .init(rawValue: code), message: message))) {
            try await client(cloud).uploadBank(Data("{}".utf8))
        }
    }

    /// The sentence the contract quotes for `bank_not_empty`, which the app shows as it is.
    private static func notEmptySentence(in description: String) throws -> String {
        let quoted = try #require(description.firstMatch(of: /`bank_not_empty` \("([^"]+)"\)/))
        #expect(quoted.1.hasSuffix("Nothing was changed."))
        return String(quoted.1)
    }
}
