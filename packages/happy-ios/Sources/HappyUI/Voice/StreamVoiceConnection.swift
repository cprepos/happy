#if canImport(UIKit)
import Foundation
import HappyCore
import os

/// A call over the server's voice stream: `VoiceStreamClient` carries it and
/// `VoiceAudio` is the microphone and speaker. Audio moves between the two off
/// the main thread; only what the UI shows comes back here.
@MainActor
final class StreamVoiceConnection: VoiceConnection {
    private let client: VoiceStreamClient
    private let audio: any VoiceAudio
    private let tracker: VoiceActivityTracker
    private let disconnected: @MainActor () -> Void
    /// The protocol has no mute message, so a muted microphone just isn't sent.
    private let muted: OSAllocatedUnfairLock<Bool>
    private var listener: Task<Void, Never>?
    private var over = false
    private(set) var failure: VoiceFailure?

    private init(client: VoiceStreamClient, audio: any VoiceAudio, tracker: VoiceActivityTracker, muted: OSAllocatedUnfairLock<Bool>,
                 disconnected: @escaping @MainActor () -> Void) {
        self.client = client
        self.audio = audio
        self.tracker = tracker
        self.muted = muted
        self.disconnected = disconnected
    }

    static func connect(account: AccountSession, request: VoiceStart, context: VoiceContext,
                        activity: @escaping @MainActor (VoiceActivity) -> Void,
                        disconnected: @escaping @MainActor () -> Void) async throws -> StreamVoiceConnection {
        try await connect(client: VoiceStreamClient(account: account, context: context, start: request), audio: VoiceAudioEngine(),
                          activity: activity, disconnected: disconnected)
    }

    /// The microphone and the handshake start together, as in happy-app: frames
    /// captured before `ready` are dropped by the client, and the agent's first
    /// words wait in the client's stream until the speaker is up.
    static func connect(client: VoiceStreamClient, audio: any VoiceAudio,
                        activity: @escaping @MainActor (VoiceActivity) -> Void,
                        disconnected: @escaping @MainActor () -> Void) async throws -> StreamVoiceConnection {
        let tracker = VoiceActivityTracker(changed: activity)
        let muted = OSAllocatedUnfairLock(initialState: false)
        // The handler is set once the connection exists. A failure before that is
        // noted, and fails the start below.
        let audioFailure = OSAllocatedUnfairLock<(happened: Bool, handler: (@Sendable () -> Void)?)>(initialState: (false, nil))
        let handlers = VoiceAudioHandlers(frame: { frame in
            guard !muted.withLock({ $0 }) else { return }
            client.sendAudio(frame)
        }, speaking: { speaking in
            guard !muted.withLock({ $0 }) else { return }
            Task { @MainActor in tracker.vad(speaking ? 1 : 0) }
        }, failed: {
            let handler = audioFailure.withLock { state in
                state.happened = true
                return state.handler
            }
            // Ending the client also stops a handshake still waiting for `ready`.
            if let handler { handler() } else { Task { await client.end() } }
        })
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await client.start() }
                group.addTask { try await audio.start(handlers) }
                // Not `waitForAll`, which lets the handshake run on after audio fails to start.
                for try await _ in group {}
            }
            let connection = StreamVoiceConnection(client: client, audio: audio, tracker: tracker, muted: muted, disconnected: disconnected)
            let installed = audioFailure.withLock { state in
                guard !state.happened else { return false }
                state.handler = { [weak connection] in
                    Task { @MainActor in await connection?.ended(.connection) }
                }
                return true
            }
            guard installed else { throw VoiceAudioError.noMicrophone }
            connection.listen()
            return connection
        } catch {
            await audio.stop()
            await client.end()
            if audioFailure.withLock({ $0.happened }) { throw VoiceAudioError.noMicrophone }
            throw error
        }
    }

    /// Off the main thread: a downlink frame must not wait for the UI.
    private func listen() {
        let client = client
        let audio = audio
        listener = Task.detached { [weak self] in
            for await event in client.events {
                switch event {
                case .audio(let frame): audio.play(frame)
                case .flush: audio.flush()
                case .agentSpeaking(let speaking): await self?.tracker.agentSpeaking(speaking)
                case .ended(let failure): await self?.ended(failure)
                }
            }
        }
    }

    /// The server closed the call, or the audio gave out.
    private func ended(_ failure: VoiceFailure?) async {
        guard !over else { return }
        over = true
        self.failure = failure
        await audio.stop()
        await client.end()
        disconnected()
    }

    func end() async {
        over = true
        // The microphone goes first, so nothing more follows `end` on the socket.
        await audio.stop()
        await client.end()
        await listener?.value
    }

    func setMuted(_ muted: Bool) async throws {
        self.muted.withLock { $0 = muted }
        if muted { tracker.vad(0) }
    }

    func context(_ text: String) async throws { client.sendContext(text) }
    func prompt(_ text: String) async throws { client.sendText(text) }
}
#endif
