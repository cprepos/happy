import React, { useEffect } from 'react';
import { Platform } from 'react-native';
import { AudioContext, AudioManager, AudioRecorder } from 'react-native-audio-api';
import { registerVoiceSession } from './RealtimeSession';
import { HappyVoiceSession } from './happyVoiceSession';
import { createNativeVoiceAudio, type NativeVoiceAudioDeps } from './nativeVoiceAudio';

const nativeAudioDeps: NativeVoiceAudioDeps = {
    platform: Platform.OS === 'ios' ? 'ios' : 'android',
    createContext: (options) => new AudioContext(options),
    createRecorder: (options) => new AudioRecorder(options),
    audioManager: AudioManager,
};

/**
 * Native voice streams through happy-server over one WebSocket, like the
 * web; the app never connects to LiveKit. Audio runs on
 * react-native-audio-api (nativeVoiceAudio.ts).
 */
export const RealtimeVoiceSession: React.FC = () => {
    useEffect(() => {
        const session = new HappyVoiceSession(createNativeVoiceAudio(nativeAudioDeps));
        registerVoiceSession(session);
        return () => {
            void session.endSession();
        };
    }, []);

    return null;
};
