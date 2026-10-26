import React, { useEffect } from 'react';
import { Track, type RemoteTrack, type Room } from 'livekit-client';
import { registerVoiceSession } from './RealtimeSession';
import { LiveKitVoiceSession, type LiveKitVoicePlatform } from './livekitVoiceSession';

/**
 * Web audio: the browser only plays remote audio through media elements, so
 * each subscribed audio track gets a hidden <audio> element that is removed
 * again when the track or the room goes away.
 */
function createWebPlatform(): LiveKitVoicePlatform {
    const attached = new Map<RemoteTrack, HTMLMediaElement>();

    const detach = (track: RemoteTrack) => {
        const element = attached.get(track);
        if (!element) return;
        attached.delete(track);
        track.detach(element);
        element.remove();
    };

    return {
        async prepare() {
            if (!navigator.mediaDevices?.getUserMedia) {
                throw new Error('This browser has no microphone access (getUserMedia)');
            }
        },
        async afterConnect(room: Room) {
            // Voice starts from a button press, so this runs inside the user
            // gesture Safari requires before it lets audio play.
            try {
                await room.startAudio();
            } catch (error) {
                console.warn('[Voice] startAudio failed:', error);
            }
        },
        attachTrack(track) {
            if (track.kind !== Track.Kind.Audio || attached.has(track)) return;
            const element = track.attach();
            element.style.display = 'none';
            element.setAttribute('data-voice-agent-audio', '');
            document.body.appendChild(element);
            attached.set(track, element);
        },
        detachTrack(track) {
            detach(track);
        },
        async cleanup() {
            for (const track of Array.from(attached.keys())) {
                detach(track);
            }
        },
    };
}

export const RealtimeVoiceSession: React.FC = () => {
    useEffect(() => {
        const session = new LiveKitVoiceSession(createWebPlatform());
        registerVoiceSession(session);
        return () => {
            void session.endSession();
        };
    }, []);

    return null;
};
