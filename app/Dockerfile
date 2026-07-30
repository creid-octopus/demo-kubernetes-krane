# Two build targets, same pattern as composite-development-loop:
#   debug   — node:20-slim, used for local iteration / CI dry-run scans
#   release — distroless, used for anything actually pushed to a registry
#
# Build args are stamped to ENV so both the web and worker processes can
# report exactly what's running (see src/common.js) — this is what makes a
# rolling update visible during a demo.

ARG NODE_VERSION=20

# ── base ──────────────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-slim AS base
WORKDIR /app
COPY package.json ./
COPY src ./src

ARG APP_VERSION=0.0.0-local
ARG APP_BRANCH=local
ARG APP_BUILD=0
ARG APP_BUILT_AT
ARG APP_COMMIT_SHA=local

ENV APP_VERSION=${APP_VERSION} \
    APP_BRANCH=${APP_BRANCH} \
    APP_BUILD=${APP_BUILD} \
    APP_BUILT_AT=${APP_BUILT_AT} \
    APP_COMMIT_SHA=${APP_COMMIT_SHA} \
    NODE_ENV=production \
    PORT=8080

EXPOSE 8080

# ── debug target ────────────────────────────────────────────────────────
# ENTRYPOINT is "node" (resolves via $PATH — node:20-slim has it there);
# the k8s Deployments supply the script name via `args`, not `command`,
# so this ENTRYPOINT is never overridden.
FROM base AS debug
ENTRYPOINT ["node"]
CMD ["src/server.js"]

# ── release target ──────────────────────────────────────────────────────
# distroless/nodejs exposes node at an absolute path, not on $PATH — so
# ENTRYPOINT must reference that path directly rather than relying on
# PATH resolution the way the debug target can.
FROM gcr.io/distroless/nodejs20-debian12 AS release
WORKDIR /app
COPY --from=base /app /app
ENV APP_VERSION=${APP_VERSION} \
    NODE_ENV=production \
    PORT=8080
EXPOSE 8080
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["src/server.js"]
