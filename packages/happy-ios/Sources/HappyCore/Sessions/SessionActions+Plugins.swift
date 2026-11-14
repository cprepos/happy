import Foundation
import HappyWire

/// Our plugins' additions to `SessionActions`, kept out of
/// SessionActions.swift so upstream merges do not conflict there.
extension SessionActions {
    /// The agent reports a reply it could not deliver (the question was
    /// already answered elsewhere, or it refused) as `{ error }` instead of
    /// failing the RPC (`throwCommunicationError`, ops.ts). Thrown here so
    /// the form stays answerable.
    static func throwCommunicationError(_ reply: JSONValue?) throws {
        if let error = reply?["error"]?.stringValue { throw SessionActionError.failed(error) }
    }
}
