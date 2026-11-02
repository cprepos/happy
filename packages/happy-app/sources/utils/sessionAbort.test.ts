import { describe, expect, it } from 'vitest';
import type { Metadata } from '@/sync/storageTypes';
import { rigMetadataFixture } from '@/sync/__testdata__/rigMetadata';
import { sessionCanAbort } from './sessionAbort';

const cli = (extra: Partial<Metadata> = {}) => ({ path: '/r', host: 'h', flavor: 'claude', ...extra } as Metadata);

describe('sessionCanAbort', () => {
    it('lets a Happy CLI session be stopped', () => {
        expect(sessionCanAbort(cli())).toBe(true);
    });

    it('never offers Stop on a Claude Desktop session', () => {
        expect(sessionCanAbort(cli({ harness: 'claude-desktop' }))).toBe(false);
    });

    it('still follows Happy Agent\'s own abort capability', () => {
        expect(sessionCanAbort({
            ...rigMetadataFixture,
            capabilities: { ...rigMetadataFixture.capabilities!, abort: false },
        })).toBe(false);
    });
});
