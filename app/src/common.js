// Shared metadata helper — both the web and worker processes report the same
// build/runtime facts, so a rolling update is visible from either side.
// Mirrors the ARG -> ENV -> process.env.* pattern used in the
// composite-development-loop reference Dockerfile.
"use strict";

function buildInfo() {
  return {
    version: process.env.APP_VERSION || "0.0.0-local",
    branch: process.env.APP_BRANCH || "local",
    build: process.env.APP_BUILD || "0",
    builtAt: process.env.APP_BUILT_AT || null,
    commitSha: process.env.APP_COMMIT_SHA || "local",
    region: process.env.REGION || "unset",
    environment: process.env.ENVIRONMENT || "unset",
    namespace: process.env.NAMESPACE || "unset",
    pod: process.env.POD_NAME || require("os").hostname(),
  };
}

module.exports = { buildInfo };
