#!/usr/bin/env node
import { createServer } from "node:http";
import { timingSafeEqual, createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

/**
 * A pretend Grok routine on the loopback, for trying the flow end to end and
 * for the tests: it takes the webhook payload when the sender header matches,
 * answers 202, then reports running and done (or error) to the job's callback.
 * It only ever calls back to a loopback address, and does nothing else with
 * what it's sent.
 */
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);

/** @param {string} a @param {string} b */
const same = (a, b) =>
  timingSafeEqual(createHash("sha256").update(a).digest(), createHash("sha256").update(b).digest());

/**
 * @param {{
 *   senderHeader?: string,
 *   senderKey: string,
 *   port?: number,
 *   outcome?: "done" | "error",
 *   delayMs?: number,
 * }} options
 */
export function createMockBot(options) {
  const header = (options.senderHeader ?? "authorization").toLowerCase();
  const outcome = options.outcome ?? "done";
  const delay = options.delayMs ?? 50;
  /** @type {object[]} */
  const received = [];

  /** @param {string} url @param {string} token @param {object} body */
  async function callback(url, token, body) {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`The callback answered ${response.status}.`);
  }

  const server = createServer(async (request, response) => {
    const given = request.headers[header];
    if (request.method !== "POST" || typeof given !== "string" || !same(given, options.senderKey)) {
      response.writeHead(401).end();
      return;
    }
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    let payload;
    try {
      payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      response.writeHead(400).end();
      return;
    }
    const target = payload?.callback?.url ? new URL(payload.callback.url) : null;
    if (!target || !LOOPBACK.has(target.hostname) || typeof payload.callback.token !== "string") {
      response.writeHead(422).end();
      return;
    }
    received.push(payload);
    response.writeHead(202, { "Content-Type": "application/json" }).end(JSON.stringify({ accepted: payload.jobId }));

    const wait = () => new Promise((resolve) => setTimeout(resolve, delay));
    try {
      await wait();
      await callback(target.href, payload.callback.token, { status: "running" });
      await wait();
      const bytes = Buffer.byteLength(JSON.stringify(payload.context ?? {}));
      await callback(
        target.href,
        payload.callback.token,
        outcome === "done"
          ? { status: "done", result: `Mock bot: "${payload.instruction}" for this ${payload.type} (${bytes} bytes of context).` }
          : { status: "error", error: "Mock bot: couldn't do that." },
      );
    } catch (error) {
      console.error(`mock-bot: ${error instanceof Error ? error.message : "callback failed"}`);
    }
  });

  return {
    server,
    received,
    /** @param {number} [port] */
    listen(port = options.port ?? 8790) {
      return new Promise((resolve) => {
        server.listen(port, "127.0.0.1", () => {
          const address = server.address();
          resolve(`http://127.0.0.1:${typeof address === "object" && address ? address.port : port}/`);
        });
      });
    },
    close() {
      return new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve(undefined));
      });
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const senderKey = process.env.MOCK_BOT_SENDER_KEY;
  if (!senderKey) throw new Error("Set MOCK_BOT_SENDER_KEY to the sender key the app sends.");
  const bot = createMockBot({
    senderHeader: process.env.MOCK_BOT_SENDER_HEADER ?? "Authorization",
    senderKey,
    port: Number(process.env.MOCK_BOT_PORT ?? 8790),
    outcome: process.env.MOCK_BOT_OUTCOME === "error" ? "error" : "done",
    delayMs: Number(process.env.MOCK_BOT_DELAY_MS ?? 1500),
  });
  console.log(`mock-bot on ${await bot.listen()}`);
}
