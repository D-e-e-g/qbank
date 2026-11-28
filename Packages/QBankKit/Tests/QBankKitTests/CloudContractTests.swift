import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing

@testable import QBankKit

/// The two Cloud calls, `GET /api/me/cloud` and `POST /api/me/cloud/transactions`, against the pinned
/// server contract (`Fixtures/openapi.json`): what each sends, that every field the kit reads or sends
/// is the contract's, and that the server's answers decode. There is no recording of a purchase, since
/// only a transaction Apple signed gets past the route, so the answers here are shaped by the
/// contract's `CloudBankStatus`, `CloudStatus` and `Error` schemas. Invented data only.
@Suite("Contract: Cloud")
struct CloudContractTests {
    /// Answers each "METHOD /path" from a table, and keeps every request.
    private final class Answers: HTTPTransport {
        private let table: [String: (Int, String)]
        private let seen = Mutex<[URLRequest]>([])

        init(_ table: [String: (Int, String)]) { self.table = table }

        var requests: [URLRequest] { seen.withLock { $0 } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            seen.withLock { $0.append(request) }
            let url = try #require(request.url)
            guard let (status, body) = table["\(request.httpMethod ?? "GET") \(url.path)"] else { throw URLError(.cannotConnectToHost) }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    private static let token = "00000000-0000-4000-8000-000000000001"
    private static let storeAccount = #"{"active":false,"bankStamp":null,"combinePaused":false,"expiresAt":null,"storeToken":"\#(token)"}"#
    private static let lapsedWithABank = #"{"active":false,"bankStamp":"opaque/server=7","combinePaused":true,"expiresAt":"2026-12-03T00:00:00.000Z","storeToken":"\#(token)"}"#
    private static let subscribed = #"{"active":true,"expiresAt":"2027-12-03T00:00:00.000Z","storeToken":"\#(token)"}"#
    private static let invited = #"{"active":true,"bankStamp":"opaque/server=1","combinePaused":false,"expiresAt":null,"storeToken":null}"#

    private static func spec() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// A schema of the contract with its `$ref` and `allOf` parts merged, however deep: every property
    /// it names, and the ones it requires.
    private static func fields(of name: String, in spec: JSONValue) throws -> (properties: Set<String>, required: Set<String>) {
        let schema = try #require(spec["components"]?["schemas"]?[name], "no schema \(name)")
        return try fields(of: schema, in: spec)
    }

    private static func fields(of schema: JSONValue, in spec: JSONValue) throws -> (properties: Set<String>, required: Set<String>) {
        if let ref = schema["$ref"]?.stringValue {
            return try fields(of: String(ref.split(separator: "/").last ?? ""), in: spec)
        }
        var properties = Set<String>()
        var required = Set<String>()
        if let parts = schema["allOf"]?.arrayValue {
            for part in parts {
                let merged = try fields(of: part, in: spec)
                properties.formUnion(merged.properties)
                required.formUnion(merged.required)
            }
        }
        if case .object(let named)? = schema["properties"] { properties.formUnion(named.keys) }
        required.formUnion((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        return (properties, required)
    }

    private func client(_ transport: any HTTPTransport) -> QBankClient {
        QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: transport,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
    }

    // MARK: The contract

    @Test func bothRoutesAreTheContractsAndAnswerCloudStatus() throws {
        let spec = try Self.spec()
        let read = try #require(spec["paths"]?["/api/me/cloud"]?["get"])
        let record = try #require(spec["paths"]?["/api/me/cloud/transactions"]?["post"])
        for (operation, schema) in [(read, "CloudBankStatus"), (record, "CloudStatus")] {
            #expect(operation["responses"]?["200"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue == "#/components/schemas/\(schema)")
        }
        let bankStatus = try #require(spec["components"]?["schemas"]?["CloudBankStatus"]?["allOf"]?.arrayValue)
        #expect(bankStatus.contains { $0["$ref"]?.stringValue == "#/components/schemas/CloudStatus" })
        let body = try #require(record["requestBody"]?["content"]?["application/json"]?["schema"]?["$ref"]?.stringValue)
        #expect(body == "#/components/schemas/CloudTransaction")
    }

    @Test func theKitReadsEveryFieldOfCloudBankStatusAndNoOther() throws {
        let (properties, required) = try Self.fields(of: "CloudBankStatus", in: Self.spec())
        let read = Set(CloudStatus.CodingKeys.allCases.map(\.stringValue))
        #expect(read == properties)
        #expect(required == properties, "every field is always sent, null when there is none")
        let (transaction, _) = try Self.fields(of: "CloudStatus", in: Self.spec())
        #expect(transaction == ["active", "expiresAt", "storeToken"], "the answer to a transaction says nothing of the bank")
    }

    @Test func theKitSendsTheTransactionAsTheContractNamesIt() throws {
        let (properties, required) = try Self.fields(of: "CloudTransaction", in: Self.spec())
        #expect(properties == ["signedTransaction"])
        #expect(required == ["signedTransaction"])
    }

    @Test func thePlansAreTheTwoProductsTheServerTakes() throws {
        let description = try #require(Self.spec()["paths"]?["/api/me/cloud/transactions"]?["post"]?["description"]?.stringValue)
        for product in CloudProducts.all {
            #expect(description.contains(product), "the server does not name \(product)")
        }
        #expect(CloudProducts.all == ["com.dimitrygallego.qbank.cloud.monthly", "com.dimitrygallego.qbank.cloud.yearly"])
    }

    @Test func theRefusalsTheAppSaysAreTheContracts() throws {
        let responses = try #require(Self.spec()["paths"]?["/api/me/cloud/transactions"]?["post"]?["responses"])
        #expect(responses["409"]?["description"]?.stringValue?.contains("`transaction_other_account`") == true)
        #expect(responses["400"]?["description"]?.stringValue?.contains("`transaction_unverified`") == true)
        #expect(responses["503"]?["description"]?.stringValue?.contains("`store_not_set_up`") == true)
    }

    // MARK: Reading how the account stands

    @Test func aStoreAccountReadsItsCloudAndTheTokenItBuysWith() async throws {
        let transport = Answers(["GET /api/me/cloud": (200, Self.storeAccount)])
        let status = try await client(transport).cloudStatus()
        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/api/me/cloud")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        #expect(sent.httpBody == nil)
        #expect(status == CloudStatus(active: false, expiresAt: nil, storeToken: UUID(uuidString: Self.token), bank: .init(stamp: nil, combinePaused: false)))
    }

    @Test func anAccountWithoutCloudReadsTheStampOfItsBankAndWhetherCombiningIsPaused() async throws {
        let status = try await client(Answers(["GET /api/me/cloud": (200, Self.lapsedWithABank)])).cloudStatus()
        #expect(!status.active)
        #expect(status.bank == CloudStatus.Bank(stamp: "opaque/server=7", combinePaused: true))
        let again = try QBankJSON.decoder.decode(CloudStatus.self, from: QBankJSON.encoder.encode(status))
        #expect(again == status, "a status kept on the phone reads back as it was")
    }

    @Test func anInvitedAccountHasCloudAndNoToken() async throws {
        let status = try await client(Answers(["GET /api/me/cloud": (200, Self.invited)])).cloudStatus()
        #expect(status.active)
        #expect(status.expiresAt == nil)
        #expect(status.storeToken == nil)
    }

    // MARK: Sending a purchase

    @Test func aTransactionGoesAsAppleSignedItAndTheAnswerIsTheCloudItLeaves() async throws {
        let transport = Answers(["POST /api/me/cloud/transactions": (200, Self.subscribed)])
        let status = try await client(transport).recordCloudTransaction("synthetic.signed.transaction")
        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        #expect(body == .object(["signedTransaction": .string("synthetic.signed.transaction")]))
        #expect(status.active)
        #expect(status.expiresAt == QBankJSON.parseDate("2027-12-03T00:00:00.000Z"))
        #expect(status.storeToken == UUID(uuidString: Self.token))
        #expect(status.bank == nil, "the answer to a transaction says nothing of the bank")
    }

    @Test func aTransactionBoughtForAnotherAccountIsRefusedInTheServersWords() async throws {
        let message = "This App Store subscription belongs to another QBank account. Nothing was recorded."
        let transport = Answers(["POST /api/me/cloud/transactions": (409, #"{"error":"transaction_other_account","message":"\#(message)"}"#)])
        let error = await #expect(throws: QBankError.self) {
            try await client(transport).recordCloudTransaction("synthetic.signed.transaction")
        }
        #expect(error?.serverCode == "transaction_other_account")
        #expect(error == .server(ServerError(status: 409, code: "transaction_other_account", message: message)))
        #expect(error?.isTemporary == false)
    }

    @Test func aServerNotSetUpForPurchasesIsAFailureToTryAgain() async throws {
        let body = #"{"error":"store_not_set_up","message":"This server can't check App Store purchases yet. Nothing was recorded; try again later."}"#
        let error = await #expect(throws: QBankError.self) {
            try await client(Answers(["POST /api/me/cloud/transactions": (503, body)])).recordCloudTransaction("synthetic.signed.transaction")
        }
        #expect(error?.isTemporary == true)
    }
}
