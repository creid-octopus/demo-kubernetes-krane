// Minimal worker process — same image as the web process, different
// command (see k8s/templates/deployment-worker.yml.erb). Just heartbeats on
// an interval so `kubectl logs` shows a visible version bump during a
// rolling update, same as the web process's build info.
"use strict";

const { buildInfo } = require("./common");

const INTERVAL_MS = Number(process.env.WORKER_INTERVAL_MS || 5000);

function tick() {
  const info = buildInfo();
  console.log(
    `[worker] heartbeat version=${info.version} region=${info.region} namespace=${info.namespace} pod=${info.pod}`
  );
}

console.log(`[worker] starting — version ${buildInfo().version}`);
tick();
const timer = setInterval(tick, INTERVAL_MS);

process.on("SIGTERM", () => {
  console.log("[worker] SIGTERM received, shutting down");
  clearInterval(timer);
  process.exit(0);
});
