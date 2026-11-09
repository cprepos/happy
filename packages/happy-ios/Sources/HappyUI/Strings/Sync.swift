import Foundation

// This app's own: asking the server again for a list or a chat.
extension Strings {
    public enum Sync {
        /// Pull-to-refresh's VoiceOver action and the Command-R command.
        public static let refresh = "Refresh"
        /// A refresh ran out of time before the connection came back; the
        /// list stays as it was and keeps trying.
        public static let stillReconnecting = "Still reconnecting…"
    }
}
