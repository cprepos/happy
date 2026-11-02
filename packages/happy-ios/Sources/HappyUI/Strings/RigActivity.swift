extension Strings {
    /// RigActivityBar.tsx's agent panel (not in en.ts): English, as it writes them.
    public enum RigActivity {
        /// The pill that stands in when no indicator counts the agents.
        public static func running(_ count: Int) -> String { "\(count) running" }
        /// VoiceOver's word for an open panel or row; RN says nothing here.
        public static let expanded = "Expanded"
        /// VoiceOver's word for a closed panel or row; RN says nothing here.
        public static let collapsed = "Collapsed"
    }
}
