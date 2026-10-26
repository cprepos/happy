# Deployment

This document describes how to deploy the Happy backend (`packages/happy-server`) and the infrastructure it expects.

## Runtime overview
- **App server:** Node.js running `tsx ./sources/main.ts` (Fastify + Socket.IO).
- **Database:** Postgres via Prisma.
- **Cache:** Redis (optional; only pinged at startup when `REDIS_URL` is set).
- **Object storage:** S3-compatible storage (optional; MinIO works). Without `S3_HOST` the server stores files on local disk.
- **Metrics:** Optional Prometheus `/metrics` server on a separate port.

## Services
1. **Postgres** (required)
   - Required for all persisted data.
   - Configure via `DATABASE_URL`.
   - Standalone mode (`sources/standalone.ts`) uses embedded PGlite instead and needs no Postgres.

2. **Redis** (optional)
   - `sources/main.ts` connects and calls `redis.ping()` only when `REDIS_URL` is set; otherwise Redis is skipped entirely.
   - Managed by this repo for prod: `packages/happy-server/deploy/happy-redis.yaml` (StatefulSet + redis-exporter sidecar).

3. **S3-compatible storage** (optional)
   - Used for avatars and other uploaded assets when `S3_HOST` is set.
   - Configure via `S3_HOST`, `S3_PORT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_PUBLIC_URL`, `S3_USE_SSL`, `S3_REGION`.
   - If `S3_HOST` is unset (`sources/storage/files.ts`), the server falls back to local filesystem storage under `$DATA_DIR/files/` (default `./data/files/`) and serves it at `/files/*`, building links from `PUBLIC_URL`.
   - In prod, the S3-compatible service behind `S3_PUBLIC_URL` is provisioned by external infrastructure; credentials come from Vault via ExternalSecret (`/handy-files`).
   - For local k8s dev, a MinIO pod is deployed via `deploy/overlays/local/minio.yaml`.

## Environment variables
**Required**
- `DATABASE_URL`: Postgres connection string.
- `HANDY_MASTER_SECRET`: master key for auth tokens and server-side encryption.

**Common**
- `PORT`: API server port (default `3005`).
- `PUBLIC_URL`: public base URL, used for local-storage file links.
- `DATA_DIR`: local data directory (default `./data`); files live in `$DATA_DIR/files`.
- `HAPPY_STATIC_DIR`: directory with a built webapp (`index.html`) to serve at `/`.
- `HAPPY_INJECT_HTML_CONFIG`: JSON exposed to the served webapp as `window.__HAPPY_CONFIG__`.
- `REDIS_URL`: optional Redis connection string.
- `S3_HOST`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_PUBLIC_URL`: optional object storage config (local disk when unset).
- `METRICS_ENABLED`: set to `false` to disable metrics server.
- `METRICS_PORT`: metrics server port (default `9090`).
- `S3_PORT`: optional S3 port.
- `S3_USE_SSL`: `true`/`false` (default `true`).

**Optional integrations**
- GitHub OAuth/App: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY`, `GITHUB_WEBHOOK_SECRET`, plus redirect URL/URI.
  - `GITHUB_REDIRECT_URL` is used by the OAuth callback handler.
  - `GITHUB_REDIRECT_URI` is used by the GitHub App initializer.
- Voice: `ELEVENLABS_API_KEY` (required for `/v1/voice/conversations` in production).
- Subscriptions: `REVENUECAT_API_KEY` (server-side RevenueCat key, required for voice subscription checks).
- Debug logging: `DANGEROUSLY_LOG_TO_SERVER_FOR_AI_AUTO_DEBUGGING` (enables file logging + dev log endpoint).

## Docker image
A production Dockerfile is provided at `Dockerfile.server`.

Key notes:
- The server defaults to port `3005` (set `PORT` explicitly in container environments); the image exposes `3005`.
- `selfhost/docker-compose.yml` is a single-host example: Postgres plus the server, local file storage, no Redis or S3.
- The image includes FFmpeg and Python for media processing.

## Kubernetes manifests
Example manifests live in `packages/happy-server/deploy`:
- `handy.yaml`: Deployment + Service + ExternalSecrets for the server.
- `happy-redis.yaml`: Redis StatefulSet + Service + ConfigMap.

The deployment config expects:
- Prometheus scraping annotations on port `9090`.
- A secret named `handy-secrets` populated by ExternalSecrets.
- A service mapping port `3000` to container port `3005`.

## Production deployment order

The `Lab_HappyServer` TeamCity build runs Build, Push, and its private Deploy
recipe in order. The recipe runs `prisma migrate deploy` in a one-off
Kubernetes Job using the new image and `handy-secrets`, then applies
`handy.yaml` and waits for the rollout. A failed migration exits before apply.

GitHub CI continues to apply migrations to its disposable Postgres database.
Production migrations run before the rolling update, so they must remain
compatible with the currently running release; destructive changes require an
expand/contract deployment.

## Local dev helpers
The server package includes scripts for local infrastructure:
- `pnpm --filter happy-server db` (Postgres in Docker)
- `pnpm --filter happy-server redis`
- `pnpm --filter happy-server s3` + `s3:init`

Use `.env`/`.env.dev` to load local settings when running `pnpm --filter happy-server dev`.

## Implementation references
- Entrypoint: `packages/happy-server/sources/main.ts`
- Dockerfile: `Dockerfile.server`
- Kubernetes manifests: `packages/happy-server/deploy`
- Env usage: `packages/happy-server/sources` (`rg -n "process.env"`)
