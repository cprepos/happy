/**
 * HTTP control server for daemon management
 * Provides endpoints for listing sessions, stopping sessions, and daemon shutdown
 */

import fastify, { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { serializerCompiler, validatorCompiler, ZodTypeProvider } from 'fastify-type-provider-zod';
import { logger } from '@/ui/logger';
import { Metadata } from '@/api/types';
import { decodeBase64 } from '@/api/encryption';
import { TrackedSession, SessionEncryptionData } from './types';
import { SpawnSessionOptions, SpawnSessionResult } from '@/modules/common/registerCommonHandlers';
import { DesktopHub, DESKTOP_MAX_WAIT_MS } from './desktopHub';

/** Aborts when the client goes away before the reply is written (long-polls). */
function abortOnClientClose(raw: { on: (event: 'close', listener: () => void) => void; writableEnded: boolean }): AbortSignal {
  const controller = new AbortController();
  raw.on('close', () => {
    if (!raw.writableEnded) controller.abort();
  });
  return controller.signal;
}

export function startDaemonControlServer({
  getChildren,
  stopSession,
  spawnSession,
  requestShutdown,
  onHappySessionWebhook,
  getConnectionStatus,
  desktopHub,
}: {
  getChildren: () => TrackedSession[];
  stopSession: (sessionId: string) => boolean;
  spawnSession: (options: SpawnSessionOptions) => Promise<SpawnSessionResult>;
  requestShutdown: () => void;
  onHappySessionWebhook: (sessionId: string, metadata: Metadata, encryption?: SessionEncryptionData) => void;
  getConnectionStatus?: () => { machineId: string; cliVersion: string; serverUrl: string; connected: boolean };
  /** Claude Desktop sessions (docs/plans/happyify-desktop-sync.md, "Daemon routes"). */
  desktopHub?: DesktopHub;
}): Promise<{ port: number; stop: () => Promise<void> }> {
  return new Promise((resolve) => {
    const app = fastify({
      logger: false // We use our own logger
    });

    // Set up Zod type provider
    app.setValidatorCompiler(validatorCompiler);
    app.setSerializerCompiler(serializerCompiler);
    const typed = app.withTypeProvider<ZodTypeProvider>();

    typed.post('/status', async () => getConnectionStatus?.() ?? { machineId: null, connected: false });

    // Session reports itself after creation
    typed.post('/session-started', {
      schema: {
        body: z.object({
          sessionId: z.string(),
          metadata: z.any(),
          encryption: z.object({
            encryptionKey: z.string(),
            encryptionVariant: z.enum(['legacy', 'dataKey']),
            seq: z.number(),
            metadataVersion: z.number(),
            agentStateVersion: z.number(),
          }).optional()
        }),
        response: {
          200: z.object({
            status: z.literal('ok')
          })
        }
      }
    }, async (request) => {
      const { sessionId, metadata, encryption } = request.body;

      logger.debug(`[CONTROL SERVER] Session started: ${sessionId}`);

      let encryptionData: SessionEncryptionData | undefined;
      if (encryption) {
        encryptionData = {
          encryptionKey: decodeBase64(encryption.encryptionKey),
          encryptionVariant: encryption.encryptionVariant,
          seq: encryption.seq,
          metadataVersion: encryption.metadataVersion,
          agentStateVersion: encryption.agentStateVersion,
        };
      }

      onHappySessionWebhook(sessionId, metadata, encryptionData);

      return { status: 'ok' as const };
    });

    // List all tracked sessions
    typed.post('/list', {
      schema: {
        response: {
          200: z.object({
            children: z.array(z.object({
              startedBy: z.string(),
              happySessionId: z.string(),
              pid: z.number()
            }))
          })
        }
      }
    }, async () => {
      const children = getChildren();
      logger.debug(`[CONTROL SERVER] Listing ${children.length} sessions`);
      return { 
        children: children
          .filter(child => child.happySessionId !== undefined)
          .map(child => ({
            startedBy: child.startedBy,
            happySessionId: child.happySessionId!,
            pid: child.pid
          }))
      }
    });

    // Stop specific session
    typed.post('/stop-session', {
      schema: {
        body: z.object({
          sessionId: z.string()
        }),
        response: {
          200: z.object({
            success: z.boolean()
          })
        }
      }
    }, async (request) => {
      const { sessionId } = request.body;

      logger.debug(`[CONTROL SERVER] Stop session request: ${sessionId}`);
      const success = stopSession(sessionId);
      return { success };
    });

    // Spawn new session
    typed.post('/spawn-session', {
      schema: {
        body: z.object({
          directory: z.string(),
          sessionId: z.string().optional(),
          agent: z.enum(['claude', 'codex', 'gemini', 'openclaw', 'agy', 'opencode', 'claude-desktop']).optional(),
          permissionMode: z.string().optional(),
          modelMode: z.string().optional(),
          effortLevel: z.string().optional(),
          environmentVariables: z.record(z.string(), z.string()).optional(),
        }),
        response: {
          200: z.object({
            success: z.boolean(),
            sessionId: z.string().optional(),
            approvedNewDirectoryCreation: z.boolean().optional()
          }),
          409: z.object({
            success: z.boolean(),
            requiresUserApproval: z.boolean().optional(),
            actionRequired: z.string().optional(),
            directory: z.string().optional()
          }),
          500: z.object({
            success: z.boolean(),
            error: z.string().optional()
          })
        }
      }
    }, async (request, reply) => {
      const { directory, sessionId, agent, permissionMode, modelMode, effortLevel, environmentVariables } = request.body;

      logger.debug(`[CONTROL SERVER] Spawn session request: dir=${directory}, sessionId=${sessionId || 'new'}, agent=${agent || 'default'}`);
      const result = await spawnSession({ directory, sessionId, agent, permissionMode, modelMode, effortLevel, environmentVariables });

      switch (result.type) {
        case 'success':
          // Check if sessionId exists, if not return error
          if (!result.sessionId) {
            reply.code(500);
            return {
              success: false,
              error: 'Failed to spawn session: no session ID returned'
            };
          }
          return {
            success: true,
            sessionId: result.sessionId,
            approvedNewDirectoryCreation: true
          };
        
        case 'requestToApproveDirectoryCreation':
          reply.code(409); // Conflict - user input needed
          return { 
            success: false,
            requiresUserApproval: true,
            actionRequired: 'CREATE_DIRECTORY',
            directory: result.directory
          };
        
        case 'error':
          reply.code(500);
          return { 
            success: false,
            error: result.errorMessage
          };
      }
    });

    if (desktopHub) {
      const claudeSessionBody = z.object({ claudeSessionId: z.string().min(1) });
      const okReply = { 200: z.object({ ok: z.literal(true) }), 404: z.object({ error: z.string() }) };
      const sessionParams = z.object({ claudeSessionId: z.string().min(1) });
      const unknownSession = (claudeSessionId: string) => ({ error: `Unknown desktop session ${claudeSessionId}` });

      // SessionStart: mirror this desktop session (idempotent per id; a new id
      // from the same pid re-points the existing mirror).
      typed.post('/desktop/adopt', {
        schema: {
          body: z.object({
            claudeSessionId: z.string().min(1),
            transcriptPath: z.string().min(1),
            cwd: z.string().min(1),
            pid: z.number().int().positive(),
          }),
          response: {
            200: z.object({ happySessionId: z.string() }),
            500: z.object({ error: z.string() }),
          }
        }
      }, async (request, reply) => {
        logger.debug(`[CONTROL SERVER] Desktop adopt ${request.body.claudeSessionId} (PID ${request.body.pid})`);
        const result = await desktopHub.adopt(request.body);
        if (result.type === 'error') {
          reply.code(500);
          return { error: result.errorMessage };
        }
        return { happySessionId: result.happySessionId };
      });

      // A running mirror re-registers after a daemon restart.
      typed.post('/desktop/reattach', {
        schema: {
          body: z.object({
            claudeSessionId: z.string().min(1),
            transcriptPath: z.string().min(1),
            cwd: z.string().min(1),
            pid: z.number().int().positive(),
            happySessionId: z.string().min(1),
            attachPid: z.number().int().positive(),
          }),
          response: okReply,
        }
      }, async (request) => {
        logger.debug(`[CONTROL SERVER] Desktop reattach ${request.body.claudeSessionId} as ${request.body.happySessionId}`);
        desktopHub.reattach(request.body);
        return { ok: true as const };
      });

      // UserPromptSubmit / Stop / SessionEnd.
      for (const type of ['busy', 'idle', 'ended'] as const) {
        typed.post(`/desktop/${type}`, {
          schema: { body: claudeSessionBody, response: okReply }
        }, async (request, reply) => {
          if (!desktopHub.report(request.body.claudeSessionId, type)) {
            reply.code(404);
            return unknownSession(request.body.claudeSessionId);
          }
          return { ok: true as const };
        });
      }

      // SessionStart / Stop (asyncRewake) long-poll. Only the newest waiter
      // receives; older ones get 204 as soon as a newer one arrives.
      typed.get('/desktop/inbox/:claudeSessionId', {
        schema: {
          params: sessionParams,
          querystring: z.object({ wait: z.coerce.number().int().min(0).default(0) }),
          response: {
            200: z.object({ localId: z.string(), text: z.string() }),
            204: z.null(),
          }
        }
      }, async (request, reply) => {
        const { claudeSessionId } = request.params;
        // An id not adopted yet is held too: SessionStart's wait can beat its adopt.
        const message = await desktopHub.waitForInbox(claudeSessionId, Math.min(request.query.wait, DESKTOP_MAX_WAIT_MS), abortOnClientClose(reply.raw));
        if (!message) return reply.code(204).send(null);
        return message;
      });

      // attach process: queue a phone message for the desktop session.
      typed.post('/desktop/enqueue', {
        schema: {
          body: z.object({ claudeSessionId: z.string().min(1), localId: z.string().min(1), text: z.string() }),
          response: {
            200: z.object({ queued: z.number() }),
            404: z.object({ error: z.string() }),
          }
        }
      }, async (request, reply) => {
        const { claudeSessionId, localId, text } = request.body;
        const queued = desktopHub.enqueue(claudeSessionId, { localId, text });
        if (queued === undefined) {
          reply.code(404);
          return unknownSession(claudeSessionId);
        }
        return { queued };
      });

      // attach process: busy / idle / ended / delivered, long-polled by seq.
      typed.get('/desktop/events/:claudeSessionId', {
        schema: {
          params: sessionParams,
          querystring: z.object({
            after: z.coerce.number().int().min(0).default(0),
            wait: z.coerce.number().int().min(0).default(0),
          }),
          response: {
            200: z.object({
              seq: z.number(),
              events: z.array(z.object({
                type: z.enum(['busy', 'idle', 'ended', 'delivered']),
                localId: z.string().optional(),
                claudeSessionId: z.string().optional(),
                transcriptPath: z.string().optional(),
              })),
            }),
            404: z.object({ error: z.string() }),
          }
        }
      }, async (request, reply) => {
        const { claudeSessionId } = request.params;
        const result = await desktopHub.readEvents(claudeSessionId, request.query.after, Math.min(request.query.wait, DESKTOP_MAX_WAIT_MS), abortOnClientClose(reply.raw));
        if (!result) {
          reply.code(404);
          return unknownSession(claudeSessionId);
        }
        return result;
      });
    }

    // Stop daemon
    typed.post('/stop', {
      schema: {
        response: {
          200: z.object({
            status: z.string()
          })
        }
      }
    }, async () => {
      logger.debug('[CONTROL SERVER] Stop daemon request received');

      // Give time for response to arrive
      setTimeout(() => {
        logger.debug('[CONTROL SERVER] Triggering daemon shutdown');
        requestShutdown();
      }, 50);

      return { status: 'stopping' };
    });

    app.listen({ port: 0, host: '127.0.0.1' }, (err, address) => {
      if (err) {
        logger.debug('[CONTROL SERVER] Failed to start:', err);
        throw err;
      }

      const port = parseInt(address.split(':').pop()!);
      logger.debug(`[CONTROL SERVER] Started on port ${port}`);

      resolve({
        port,
        stop: async () => {
          logger.debug('[CONTROL SERVER] Stopping server');
          await app.close();
          logger.debug('[CONTROL SERVER] Server stopped');
        }
      });
    });
  });
}
