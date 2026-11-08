#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createJobService } from "../src/server.mjs";

/**
 * Starts the job service from the environment (README.md): the app token
 * from GROK_JOBS_APP_TOKEN_FILE (or GROK_JOBS_APP_TOKEN), on 127.0.0.1. The
 * callback address handed to bots is GROK_JOBS_PUBLIC_URL: reaching it from
 * the internet (Tailscale Funnel, a tunnel) is set up separately, by the user.
 */
const env = process.env;
const appToken = env.GROK_JOBS_APP_TOKEN_FILE
  ? readFileSync(env.GROK_JOBS_APP_TOKEN_FILE, "utf8").trim()
  : (env.GROK_JOBS_APP_TOKEN ?? "");
const port = Number(env.GROK_JOBS_PORT ?? 8789);
const publicUrl = env.GROK_JOBS_PUBLIC_URL;
if (publicUrl) {
  const url = new URL(publicUrl);
  const loopback = ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new Error("GROK_JOBS_PUBLIC_URL must be https (or http on the loopback, for the mock bot).");
  }
}

const service = await createJobService({
  appToken,
  dataFile: env.GROK_JOBS_DATA ?? join(homedir(), ".otter-mail", "grok-jobs", "jobs.json"),
  publicUrl,
  host: env.GROK_JOBS_HOST ?? "127.0.0.1",
  port,
  log: (line) => console.log(line),
});
const { url, publicUrl: callbacks } = await service.listen();
console.log(`grok-jobs on ${url}; callbacks go to ${callbacks}/jobs/<id>/result`);

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    service.close().then(() => process.exit(0));
  });
}
