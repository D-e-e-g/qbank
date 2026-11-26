import Foundation

/// A request the bank on the phone refuses, in the server's own shape and words: the status, the
/// `error` code a client tells refusals apart by, and the sentence the person reads. Most refusals
/// are `request_refused`; a body that does not fit the contract is `invalid_request`.
struct BankRefusal: Error, Equatable {
    let status: Int
    let code: String
    let message: String

    /// A refusal the app words: 400, 404 or 409.
    static func refused(_ status: Int, _ message: String) -> BankRefusal {
        BankRefusal(status: status, code: "request_refused", message: message)
    }

    /// A body, query or id that does not fit the contract (the server's schema check, before any rule).
    static let invalidRequest = BankRefusal(status: 400, code: "invalid_request", message: "Check the fields and try again.")

    /// A path the engine does not serve, so a stray call fails loudly (design record, rule 7).
    static func notServed(_ method: String, _ path: String) -> BankRefusal {
        BankRefusal(status: 404, code: "not_found", message: "The bank on this phone does not answer \(method) \(path).")
    }

    /// A write while the bank is moving to QBank Cloud, which holds it as it is until the move ends.
    /// The phone's own refusal: the server has no bank that moves.
    static let moving = BankRefusal(
        status: 409, code: "bank_moving", message: "Your bank is moving to QBank Cloud, so it cannot change until the move ends. Nothing was changed.")

    /// What goes wrong inside the engine that no rule explains, as the server words it.
    static let failed = BankRefusal(status: 500, code: "server_error", message: "Something went wrong. Try again.")

    var body: JSONValue { .object(["error": .string(code), "message": .string(message)]) }
}

/// What a route answers: a status and a JSON body, or no body.
struct BankAnswer: Sendable {
    let status: Int
    let body: JSONValue?

    static func ok(_ body: JSONValue) -> BankAnswer { BankAnswer(status: 200, body: body) }
    static func created(_ body: JSONValue) -> BankAnswer { BankAnswer(status: 201, body: body) }
}

extension JSONValue {
    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}
