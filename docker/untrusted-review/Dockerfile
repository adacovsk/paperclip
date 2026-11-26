# Same Node as the app image (see the root Dockerfile for why it is pinned and
# not `node:lts`: Node 25+ dropped the corepack this image enables).
FROM node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0 AS base
RUN corepack enable

# The same pinned agent CLIs as the app image, from docker/agent-clis.
FROM base AS agent-clis
WORKDIR /opt/agent-clis
COPY docker/agent-clis/package.json docker/agent-clis/pnpm-workspace.yaml docker/agent-clis/pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --prod --store-dir=/pnpm/store

FROM base

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    fd-find \
    gh \
    git \
    jq \
    less \
    openssh-client \
    procps \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

COPY --from=agent-clis /opt/agent-clis /opt/agent-clis

RUN useradd --create-home --shell /bin/bash reviewer

ENV HOME=/home/reviewer \
  CODEX_HOME=/home/reviewer/.codex \
  CLAUDE_HOME=/home/reviewer/.claude \
  PAPERCLIP_HOME=/home/reviewer/.paperclip-review \
  PNPM_HOME=/home/reviewer/.local/share/pnpm \
  PATH=/home/reviewer/.local/share/pnpm:/opt/agent-clis/node_modules/.bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work

COPY --chown=reviewer:reviewer docker/untrusted-review/bin/review-checkout-pr /usr/local/bin/review-checkout-pr

RUN chmod +x /usr/local/bin/review-checkout-pr \
  && mkdir -p /work \
  && chown -R reviewer:reviewer /work

USER reviewer

EXPOSE 3100 5173

CMD ["bash", "-l"]
