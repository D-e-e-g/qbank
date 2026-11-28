import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// `POST /api/me/bank/combine`, the store of a bank the phone combined with the server's, against the
/// pinned server contract (`Fixtures/openapi.json`): what the kit sends, that the answer it reads is the
/// contract's `BankCombined`, and that every refusal the contract names decodes with its code. Invented
/// data only.
@Suite("Contract: the bank combine")
struct BankCombineContractTests {
    private static func spec() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private static func route() throws -> JSONValue {
        try #require(try spec()["paths"]?["/api/me/bank/combine"]?["post"])
    }

    private func client(_ cloud: CombineStandIn) -> QBankClient {
        QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
    }

    @Test func theCombineTakesAStampedArchiveAndAnswersTheCountsAndTheNewStamp() throws {
        let spec = try Self.spec()
        let route = try Self.route()
        #expect(route["requestBody"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue == "#/components/schemas/CombinedBankArchive")
        #expect(route["responses"]?["200"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue == "#/components/schemas/BankCombined")
        let combined = try #require(spec["components"]?["schemas"]?["BankCombined"])
        #expect(Set(combined["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) == ["counts", "stamp"])
        #expect(combined["properties"]?["counts"]?["$ref"]?.stringValue == "#/components/schemas/BankCounts")
        let archive = try #require(spec["components"]?["schemas"]?["CombinedBankArchive"])
        let required = (archive["allOf"]?.arrayValue ?? [archive]).flatMap { $0["required"]?.arrayValue ?? [] }.compactMap(\.stringValue)
        #expect(required.contains("stamp"), "a combined archive always names the download it was built on")
        guard case .object(let responses)? = route["responses"] else {
            Issue.record("the combine documents no answers")
            return
        }
        #expect(Set(responses.keys) == ["200", "400", "401", "403", "409", "413", "503"])
    }

    @Test func theArchiveIsSentByteForByteWithTheSessionAndALongerWait() async throws {
        let world = try await ArchiveWorld.make()
        let archive = try CombineWorld.archive(world.store, server: true)
        let cloud = CombineStandIn(holding: archive)

        let combined = try await client(cloud).combineBank(archive)

        #expect(combined.counts == (try BankArchive.counts(of: world.store)))
        #expect(combined.stamp == "opaque/server=after")
        let request = try #require(cloud.requests.first)
        #expect(cloud.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/me/bank/combine")
        #expect(request.httpBody == archive)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        #expect(request.timeoutInterval == QBankClient.bankUploadTimeout)
    }

    /// Each refusal the contract documents for the combine.
    @Test(arguments: [
        (400, "invalid_archive"), (401, "unauthenticated"), (403, "not_store_account"), (403, "cloud_required"), (409, "bank_changed"),
        (409, "bank_rows_missing"), (409, "bank_rows_older"), (409, "bank_ids_taken"), (413, "archive_too_large"),
    ])
    func everyRefusalTheContractNamesDecodesWithItsCode(_ status: Int, _ code: String) async throws {
        let described = try #require(try Self.route()["responses"]?[String(status)]?["description"]?.stringValue)
        #expect(described.contains(code) || code == "unauthenticated", "the contract names \(code) under \(status)")
        let cloud = CombineStandIn(holding: Data(), combine: .answers(status, #"{"error":"\#(code)","message":"Nothing was changed."}"#))

        let error = await #expect(throws: QBankError.self) {
            try await client(cloud).combineBank(Data("{}".utf8))
        }
        #expect(error == .server(ServerError(status: status, code: .init(rawValue: code), message: "Nothing was changed.")))
        #expect((error?.serverCode == .bankChanged) == (code == "bank_changed"))
    }
}
