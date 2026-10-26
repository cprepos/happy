import React from 'react';
import { RealtimeVoiceSession } from './RealtimeVoiceSession';
import { useVoiceSessionGeneration } from '@/sync/storage';

export const RealtimeProvider = ({ children }: { children: React.ReactNode }) => {
    // Same as native: a fresh voice session (and LiveKit Room) per conversation.
    const generation = useVoiceSessionGeneration();
    return (
        <>
            <RealtimeVoiceSession key={generation} />
            {children}
        </>
    );
};
