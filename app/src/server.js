// Minimal web process. No framework, no dependencies — the point of this
// repo is the deploy mechanics, not the app. Two routes:
//   GET /        human-readable build/runtime info (what you'd eyeball
//                during a rolling update to confirm the new version is live)
//   GET /healthz liveness/readiness target for the Deployment probes
"use strict";

const http = require("http");
const { buildInfo } = require("./common");

const PORT = process.env.PORT || 8080;

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok\n");
    return;
  }

  const info = buildInfo();
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ process: "web", ...info }, null, 2) + "\n");
});

server.listen(PORT, () => {
  console.log(`[web] listening on :${PORT} — version ${buildInfo().version}`);
});

process.on("SIGTERM", () => {
  console.log("[web] SIGTERM received, shutting down");
  server.close(() => process.exit(0));
});
