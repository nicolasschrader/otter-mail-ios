import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createJobService } from "../src/server.mjs";

export const APP_TOKEN = "test-app-token-0123456789abcdef0123456789";

/** A service on a free loopback port with its own data file; `stop` takes both away. */
export async function startService(options = {}) {
  const folder = options.folder ?? (await mkdtemp(join(tmpdir(), "grok-jobs-")));
  const service = await createJobService({
    appToken: APP_TOKEN,
    dataFile: join(folder, "jobs.json"),
    ...options,
  });
  const { url, publicUrl } = await service.listen(0);
  return {
    service,
    url,
    publicUrl,
    folder,
    /** @param {string} path @param {RequestInit & { token?: string | null, json?: unknown }} [init] */
    async call(path, init = {}) {
      const { token = APP_TOKEN, json, ...rest } = init;
      const headers = new Headers(rest.headers);
      if (token) headers.set("Authorization", `Bearer ${token}`);
      if (json !== undefined) headers.set("Content-Type", "application/json");
      const response = await fetch(url + path, { ...rest, headers, body: json !== undefined ? JSON.stringify(json) : rest.body });
      const text = await response.text();
      return { status: response.status, body: text ? JSON.parse(text) : null, text };
    },
    async stop({ keep = false } = {}) {
      await service.close();
      if (!keep) await rm(folder, { recursive: true, force: true });
    },
  };
}

export function registration(overrides = {}) {
  return {
    idempotencyKey: "0b5c3f1e-4a2d-4c7e-9a10-6f1d2e3c4b5a",
    type: "task",
    sourceKey: "task:0b5c3f1e-4a2d-4c7e-9a10-6f1d2e3c4b5a",
    instruction: "Draft a reply saying yes.",
    context: { task: { content: "Say yes to dinner", notes: "", emails: [], events: [] } },
    ...overrides,
  };
}
