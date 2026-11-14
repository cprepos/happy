import Foundation
import HappyStore
import HappyWire

/// Our plugins' additions to `SessionList`: naming each row's computer
/// when the chats span more than one, kept out of SessionList.swift so
/// upstream merges do not conflict there.
extension SessionList {
    /// Whether these chats run on more than one computer, the only time
    /// naming one on each row tells the reader anything (flatSessionList.ts
    /// `hasMultipleHosts`). It counts machines, not names: two computers that
    /// share a name are still two places the work can be. Bots don't count.
    static func spansHosts(_ sessions: [SessionRecord]) -> Bool {
        var machineIds = Set<String>()
        for session in sessions where !session.isBot {
            if let id = session.metadata?["machineId"]?.stringValue, !id.isEmpty { machineIds.insert(id) }
            if machineIds.count > 1 { return true }
        }
        return false
    }

    /// utils/flatSessionList.ts `toFlatSessionRow`: the computer's name
    /// (`MachineName`: the person's, then its Happy Agent's, then its host),
    /// then the host the chat itself recorded. Nil, and no host on the row,
    /// when none of them says.
    static func hostName(_ session: SessionRecord, machines: [String: MachineRecord]) -> String? {
        func nonEmpty(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
        let machine = session.metadata?["machineId"]?.stringValue.flatMap { machines[$0] }
        return MachineName.named(machine, among: Array(machines.values))
            ?? nonEmpty(session.metadata?["host"]?.stringValue)
    }
}
