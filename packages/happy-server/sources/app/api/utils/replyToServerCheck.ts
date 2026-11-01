import { FastifyReply, FastifyRequest } from "fastify";
import { isServerCheckRequest } from "@/app/api/utils/isServerCheckRequest";

export const serverBanner = 'Welcome to Happy Server!';

/**
 * onRequest hook for a server that serves the webapp on `/`: answers a server check with the
 * banner before @fastify/static can answer it with the webapp. Every other request passes through.
 */
export async function replyToServerCheck(request: FastifyRequest, reply: FastifyReply) {
    const isCheck = isServerCheckRequest({
        method: request.method,
        url: request.url,
        accept: request.headers.accept,
    });
    if (isCheck) {
        return reply.type('text/plain').send(serverBanner);
    }
}
