export interface ServerCheckRequest {
    method: string;
    url: string;
    accept: string | undefined;
}

/**
 * Decides whether a request is an app validating a server rather than a browser opening the webapp.
 *
 * The iOS, Expo and Android apps check a server with `GET /` and look for the banner in the body.
 * A check is a GET of exactly `/` (any query string is ignored) whose Accept header does not ask
 * for `text/html`, compared case-insensitively. A missing Accept header counts as a check.
 */
export function isServerCheckRequest(request: ServerCheckRequest): boolean {
    if (request.method !== 'GET') {
        return false;
    }
    if (request.url.split('?')[0] !== '/') {
        return false;
    }
    return !request.accept?.toLowerCase().includes('text/html');
}
