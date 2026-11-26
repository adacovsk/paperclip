# Node major matches .nvmrc, which CI tests. `node:lts` moved past it to a
# release that no longer bundles corepack, and `corepack enable` below then
# fails with "not found".
#
# Pinned by digest: a tag can be re-pointed, a digest cannot. Dependabot's
# docker updates move tag and digest together after the 14-day cooldown.
# This pin is a deliberate exception to that window: 24.22.3 is a Node
# security release, and the newest image old enough still
# carries the runtime it fixes. An exception is taken for a security fix only.
FROM node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0 AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/

RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --store-dir=/pnpm/store

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

# Agent CLIs: their own pnpm project (docker/agent-clis), installed from its
# lockfile under the same release cooldown and build-script allowlist as the
# app, and bumped by Dependabot. A stage of its own so app changes never
# reinstall them, and its store sits in a cache mount rather than in the image.
FROM base AS agent-clis
WORKDIR /opt/agent-clis
COPY docker/agent-clis/package.json docker/agent-clis/pnpm-workspace.yaml docker/agent-clis/pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --prod --store-dir=/pnpm/store

FROM base AS production
# The CLI layer goes in before the app's, so an app-only change leaves this
# ~900 MB layer byte-identical and registries and pulls reuse it.
COPY --from=agent-clis /opt/agent-clis /opt/agent-clis
RUN mkdir -p /paperclip && chown node:node /paperclip
WORKDIR /app
COPY --chown=node:node --from=build /app /app

ENV NODE_ENV=production \
  PATH=/opt/agent-clis/node_modules/.bin:$PATH \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private

VOLUME ["/paperclip"]
EXPOSE 3100

USER node
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
