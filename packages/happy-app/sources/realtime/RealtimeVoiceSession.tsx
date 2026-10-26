import React, { useEffect } from 'react';
import { Platform } from 'react-native';
import { AndroidAudioTypePresets, AudioSession, registerGlobals } from '@livekit/react-native';
import { registerVoiceSession } from './RealtimeSession';
import { LiveKitVoiceSession, type LiveKitVoicePlatform } from './livekitVoiceSession';

// WebRTC globals and the polyfills livekit-client needs on React Native.
// Must run once, before the first Room is created.
let globalsRegistered = false;
function ensureGlobals() {
    if (!globalsRegistered) {
        registerGlobals();
        globalsRegistered = true;
    }
}
ensureGlobals();

/**
 * Native audio: a voice-chat audio session (echo cancellation, speaker by
 * default, Bluetooth headsets allowed) held only while a conversation runs.
 * Subscribed remote audio plays on its own on native.
 */
const nativePlatform: LiveKitVoicePlatform = {
    async prepare() {
        ensureGlobals();
        await AudioSession.configureAudio({
            android: {
                audioTypeOptions: AndroidAudioTypePresets.communication,
            },
            ios: {
                defaultOutput: 'speaker',
            },
        });
        if (Platform.OS === 'ios') {
            await AudioSession.setAppleAudioConfiguration({
                audioCategory: 'playAndRecord',
                audioCategoryOptions: ['allowBluetooth', 'allowBluetoothA2DP', 'defaultToSpeaker'],
                audioMode: 'voiceChat',
            });
        }
        await AudioSession.startAudioSession();
    },
    async cleanup() {
        await AudioSession.stopAudioSession();
    },
};

export const RealtimeVoiceSession: React.FC = () => {
    useEffect(() => {
        const session = new LiveKitVoiceSession(nativePlatform);
        registerVoiceSession(session);
        return () => {
            void session.endSession();
        };
    }, []);

    return null;
};
