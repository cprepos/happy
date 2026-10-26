import React, { useEffect } from 'react';
import { registerVoiceSession } from './RealtimeSession';
import { HappyVoiceSession } from './happyVoiceSession';
import { createWebVoiceAudio } from './webVoiceAudio';

/**
 * Web voice streams through happy-server over one WebSocket; the browser
 * never connects to LiveKit. Audio runs in AudioWorklets (webVoiceAudio.ts).
 */
export const RealtimeVoiceSession: React.FC = () => {
    useEffect(() => {
        const session = new HappyVoiceSession(createWebVoiceAudio());
        registerVoiceSession(session);
        return () => {
            void session.endSession();
        };
    }, []);

    return null;
};
