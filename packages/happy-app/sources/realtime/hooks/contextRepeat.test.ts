import { describe, expect, it } from 'vitest';
import { createRepeatFilter } from './contextRepeat';

describe('createRepeatFilter', () => {
    it('drops a byte-identical repeat inside the window', () => {
        const filter = createRepeatFilter(2000);
        // The pair the sync layer emits 1 ms apart: a tool call rendered on arrival, then
        // again when its result flips state, which the formatter does not print.
        expect(filter.isRepeat('Read(file.ts)', 1000)).toBe(false);
        expect(filter.isRepeat('Read(file.ts)', 1001)).toBe(true);
    });

    it('lets the same text through once the window has passed', () => {
        const filter = createRepeatFilter(2000);
        expect(filter.isRepeat('Read(file.ts)', 1000)).toBe(false);
        expect(filter.isRepeat('Read(file.ts)', 3001)).toBe(false);
    });

    it('does not confuse distinct updates that interleave', () => {
        const filter = createRepeatFilter(2000);
        expect(filter.isRepeat('a', 1000)).toBe(false);
        expect(filter.isRepeat('b', 1001)).toBe(false);
        expect(filter.isRepeat('a', 1002)).toBe(true);
        expect(filter.isRepeat('b', 1003)).toBe(true);
    });

    it('remembers only the most recent few, so it cannot grow without bound', () => {
        const filter = createRepeatFilter(2000, 2);
        filter.isRepeat('a', 1000);
        filter.isRepeat('b', 1001);
        filter.isRepeat('c', 1002);
        // 'a' fell off the end of a two-slot memory, so it is no longer seen as a repeat.
        expect(filter.isRepeat('a', 1003)).toBe(false);
        expect(filter.isRepeat('c', 1004)).toBe(true);
    });

    it('forgets everything on reset, as a new voice session should', () => {
        const filter = createRepeatFilter(2000);
        expect(filter.isRepeat('a', 1000)).toBe(false);
        filter.reset();
        expect(filter.isRepeat('a', 1001)).toBe(false);
    });
});
