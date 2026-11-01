import Foundation

/// Turns a connection's agent state and microphone level into the activity a
/// voice call shows: the agent speaking wins, and the user stays speaking
/// through 300 ms of silence.
@MainActor
public final class VoiceActivityTracker {
    private let changed: @MainActor (VoiceActivity) -> Void
    private var speaking = false
    private var silence: Task<Void, Never>?

    public init(changed: @escaping @MainActor (VoiceActivity) -> Void) { self.changed = changed }

    public func agentSpeaking(_ value: Bool) {
        speaking = value
        silence?.cancel(); silence = nil
        changed(value ? .agentSpeaking : .listening)
    }

    /// A voice-activity score from 0 to 1.
    public func vad(_ score: Double) {
        guard !speaking else { return }
        if score > 0.5 {
            silence?.cancel(); silence = nil
            changed(.userSpeaking)
        } else if silence == nil {
            silence = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, !self.speaking else { return }
                self.changed(.listening)
                self.silence = nil
            }
        }
    }
}
