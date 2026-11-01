import { describe, expect, it } from 'vitest';
import { isServerCheckRequest } from '@/app/api/utils/isServerCheckRequest';

const browserAccept = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8';

describe('isServerCheckRequest', () => {
    it('accepts a GET of the root asking for plain text', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/', accept: 'text/plain' })).toBe(true);
    });

    it('accepts a GET of the root asking for anything', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/', accept: '*/*' })).toBe(true);
    });

    it('treats a missing Accept header as a check', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/', accept: undefined })).toBe(true);
    });

    it('ignores the query string', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/?x=1', accept: '*/*' })).toBe(true);
    });

    it('leaves a browser navigation alone', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/', accept: browserAccept })).toBe(false);
    });

    it('leaves a browser navigation with a query string alone', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/?x=1', accept: browserAccept })).toBe(false);
    });

    it('compares the Accept header case-insensitively', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/', accept: 'TEXT/HTML' })).toBe(false);
    });

    it('rejects a path other than the root', () => {
        expect(isServerCheckRequest({ method: 'GET', url: '/index.html', accept: '*/*' })).toBe(false);
        expect(isServerCheckRequest({ method: 'GET', url: '/v1/sessions', accept: '*/*' })).toBe(false);
    });

    it('rejects a method other than GET', () => {
        expect(isServerCheckRequest({ method: 'POST', url: '/', accept: '*/*' })).toBe(false);
        expect(isServerCheckRequest({ method: 'HEAD', url: '/', accept: '*/*' })).toBe(false);
    });
});
