import React from 'react';
import { RealtimeVoiceSession } from './RealtimeVoiceSession';
import { useVoiceSessionGeneration } from '@/sync/storage';

export const RealtimeProvider = ({ children }: { children: React.ReactNode }) => {
    // A LiveKit Room can't be reused after it disconnects, so every finished
    // conversation bumps the generation and the voice session is rebuilt from
    // scratch. Children sit outside the keyed component so the app tree isn't
    // torn down on remount.
    const generation = useVoiceSessionGeneration();
    return (
        <>
            <RealtimeVoiceSession key={generation} />
            {children}
        </>
    );
};
