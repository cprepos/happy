import { describe, expect, it } from 'vitest';
import { desktopSessionTag, reduceDesktopEvents, type DesktopStatus } from './runClaudeDesktopAttach';

const idle: DesktopStatus = { thinking: false, ended: false };

describe('reduceDesktopEvents', () => {
    it('busy turns thinking on and idle turns it off', () => {
        expect(reduceDesktopEvents(idle, [{ type: 'busy' }])).toEqual({ thinking: true, ended: false });
        expect(reduceDesktopEvents({ thinking: true, ended: false }, [{ type: 'idle' }])).toEqual(idle);
    });

    it('a delivered phone message starts a turn with no busy before it', () => {
        expect(reduceDesktopEvents(idle, [{ type: 'delivered', localId: 'l1' }])).toEqual({ thinking: true, ended: false });
    });

    it('applies a batch in order, last event wins', () => {
        expect(reduceDesktopEvents(idle, [{ type: 'busy' }, { type: 'idle' }, { type: 'delivered', localId: 'l2' }]))
            .toEqual({ thinking: true, ended: false });
        expect(reduceDesktopEvents(idle, [{ type: 'delivered', localId: 'l3' }, { type: 'idle' }])).toEqual(idle);
    });

    it('ended stops thinking and sticks', () => {
        expect(reduceDesktopEvents({ thinking: true, ended: false }, [{ type: 'ended' }])).toEqual({ thinking: false, ended: true });
        expect(reduceDesktopEvents({ thinking: false, ended: true }, [{ type: 'busy' }])).toEqual({ thinking: true, ended: true });
    });

    it('no events leaves the status unchanged', () => {
        const status: DesktopStatus = { thinking: true, ended: false };
        expect(reduceDesktopEvents(status, [])).toBe(status);
    });
});

describe('desktopSessionTag', () => {
    it('is the same every time a desktop session is attached, so reopening reattaches', () => {
        const id = '5080bd4b-d549-411b-95e5-b62175d2396b';
        expect(desktopSessionTag(id)).toBe(desktopSessionTag(id));
        expect(desktopSessionTag(id)).toBe('claude-desktop:5080bd4b-d549-411b-95e5-b62175d2396b');
    });

    it('differs between desktop sessions', () => {
        expect(desktopSessionTag('a')).not.toBe(desktopSessionTag('b'));
    });
});
