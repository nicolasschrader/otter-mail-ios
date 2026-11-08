import { createServer } from "node:http";
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { JobStore } from "./store.mjs";

/**
 * Otter Mail's Grok job service (README.md has the API). It registers a job
 * for the app, hands back a callback token made for that job alone (kept only
 * as a hash), and takes the bot's running, done or error on that callback.
 * It never fetches a URL, runs nothing a bot says, and answers on the
 * loopback only: putting it on the internet is the user's own step.
 */

export const LIMITS = {
  body: 256 * 1024,
  context: 128 * 1024,
  instruction: 4000,
  sourceKey: 512,
  result: 32_000,
  error: 2000,
  jobs: 2000,
  list: 50,
};

const TYPES = new Set(["task", "mail", "event"]);
const RESULT_STATUSES = new Set(["running", "done", "error"]);
const KEY = /^[A-Za-z0-9_-]{8,100}$/;
const ID = /^[A-Za-z0-9_-]{1,100}$/;
const LOOPBACK = new Set(["127.0.0.1", "::1", "localhost"]);

class HttpError extends Error {
  /** @param {number} status @param {string} message */
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** @param {string} text */
const sha256 = (text) => createHash("sha256").update(text).digest("hex");

/** Constant-time over the digests, so neither length nor prefix leaks. @param {string} a @param {string} b */
function same(a, b) {
  return timingSafeEqual(Buffer.from(sha256(a), "hex"), Buffer.from(sha256(b), "hex"));
}

/** @param {string} hash @param {string} token */
function matchesHash(hash, token) {
  const given = Buffer.from(sha256(token), "hex");
  const kept = Buffer.from(hash, "hex");
  return kept.length === given.length && timingSafeEqual(kept, given);
}

/** @param {import("node:http").IncomingMessage} request */
function bearer(request) {
  const header = request.headers.authorization ?? "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
}

/** @param {import("./store.mjs").Job} job */
function publicJob(job) {
  return {
    id: job.id,
    type: job.type,
    sourceKey: job.sourceKey,
    status: job.status,
    result: job.result,
    error: job.error,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
  };
}

/** @param {import("node:http").IncomingMessage} request @param {number} limit */
async function readJson(request, limit) {
  const type = (request.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
  if (type !== "application/json") throw new HttpError(415, "Send application/json.");
  const declared = Number(request.headers["content-length"] ?? 0);
  if (declared > limit) throw new HttpError(413, "The body is too large.");
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw new HttpError(413, "The body is too large.");
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "The body isn't JSON.");
  }
}

/** @param {unknown} value */
const isObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

/** @param {unknown} value @param {number} max @param {string} name @param {number} [min] */
function text(value, max, name, min = 1) {
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new HttpError(400, `${name} must be a string of ${min} to ${max} characters.`);
  }
  return value;
}

/**
 * @param {{
 *   appToken: string,
 *   dataFile: string,
 *   publicUrl?: string,
 *   host?: string,
 *   port?: number,
 *   now?: () => Date,
 *   log?: (line: string) => void,
 * }} options
 */
export async function createJobService(options) {
  const host = options.host ?? "127.0.0.1";
  if (!LOOPBACK.has(host)) {
    throw new Error(`grok-jobs listens on the loopback only (127.0.0.1, ::1, localhost), not ${host}.`);
  }
  if (typeof options.appToken !== "string" || options.appToken.length < 32) {
    throw new Error("The app token must be at least 32 characters.");
  }
  const appToken = options.appToken;
  const now = options.now ?? (() => new Date());
  const log = options.log ?? (() => {});
  const store = new JobStore(options.dataFile);
  await store.load();
  /** @type {string} */
  let publicUrl = options.publicUrl ?? "";

  /** @param {string} id */
  const callbackUrl = (id) => `${publicUrl.replace(/\/+$/, "")}/jobs/${id}/result`;

  /** Room for a new job: the oldest finished go first; open jobs are never dropped. */
  async function makeRoom() {
    if (store.jobs.size < LIMITS.jobs) return;
    const finished = store
      .all()
      .filter((job) => job.status === "done" || job.status === "error")
      .sort((a, b) => a.updatedAt.localeCompare(b.updatedAt));
    const over = store.jobs.size - LIMITS.jobs + 1;
    if (finished.length < over) throw new HttpError(429, "Too many open jobs.");
    await store.remove(finished.slice(0, over).map((job) => job.id));
  }

  /** @param {import("node:http").IncomingMessage} request */
  function requireApp(request) {
    if (!same(bearer(request), appToken)) throw new HttpError(401, "Unauthorized.");
  }

  /** @param {import("node:http").IncomingMessage} request */
  async function register(request) {
    requireApp(request);
    const body = await readJson(request, LIMITS.body);
    if (!isObject(body)) throw new HttpError(400, "The body must be an object.");
    const idempotencyKey = text(body.idempotencyKey, 100, "idempotencyKey", 8);
    if (!KEY.test(idempotencyKey)) throw new HttpError(400, "idempotencyKey may hold letters, digits, - and _.");
    if (!TYPES.has(body.type)) throw new HttpError(400, "type must be task, mail or event.");
    const sourceKey = text(body.sourceKey, LIMITS.sourceKey, "sourceKey");
    const instruction = text(body.instruction, LIMITS.instruction, "instruction");
    if (!isObject(body.context)) throw new HttpError(400, "context must be an object.");
    const context = JSON.stringify(body.context);
    const contextBytes = Buffer.byteLength(context);
    if (contextBytes > LIMITS.context) throw new HttpError(413, "The context is too large.");

    const instructionSha256 = sha256(instruction);
    const contextSha256 = sha256(context);
    const known = store.byIdempotencyKey(idempotencyKey);
    if (known) {
      const matches =
        known.type === body.type &&
        known.sourceKey === sourceKey &&
        known.instructionSha256 === instructionSha256 &&
        known.contextSha256 === contextSha256;
      if (!matches) throw new HttpError(409, "This idempotencyKey was used for another job.");
      // The token went out with the first answer and isn't kept: a replay has none.
      return [200, { job: publicJob(known), replayed: true }];
    }

    await makeRoom();
    const token = randomBytes(32).toString("base64url");
    const at = now().toISOString();
    /** @type {import("./store.mjs").Job} */
    const job = {
      id: randomUUID(),
      idempotencyKey,
      type: body.type,
      sourceKey,
      instructionSha256,
      contextSha256,
      contextBytes,
      callbackSha256: sha256(token),
      status: "registered",
      result: null,
      error: null,
      createdAt: at,
      updatedAt: at,
    };
    await store.put(job);
    return [201, { job: publicJob(job), callback: { url: callbackUrl(job.id), token }, replayed: false }];
  }

  /** @param {import("node:http").IncomingMessage} request @param {URL} url */
  function list(request, url) {
    requireApp(request);
    const sourceKey = url.searchParams.get("sourceKey");
    if (sourceKey !== null) text(sourceKey, LIMITS.sourceKey, "sourceKey");
    const jobs = store
      .all()
      .filter((job) => sourceKey === null || job.sourceKey === sourceKey)
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .slice(0, LIMITS.list)
      .map(publicJob);
    return [200, { jobs }];
  }

  /** @param {import("node:http").IncomingMessage} request @param {string} id */
  function read(request, id) {
    requireApp(request);
    const job = store.get(id);
    if (!job) throw new HttpError(404, "No such job.");
    return [200, publicJob(job)];
  }

  /**
   * The bot's report, on the job's own token. A finished job stays finished:
   * the same report again is fine (a retried callback), anything else is a
   * conflict, and running never follows done or error.
   * @param {import("node:http").IncomingMessage} request @param {string} id
   */
  async function report(request, id) {
    const job = store.get(id);
    const token = bearer(request);
    // An unknown job and a wrong token answer alike.
    if (!job || !token || !matchesHash(job.callbackSha256, token)) throw new HttpError(401, "Unauthorized.");
    const body = await readJson(request, LIMITS.body);
    if (!isObject(body) || !RESULT_STATUSES.has(body.status)) {
      throw new HttpError(400, "status must be running, done or error.");
    }
    const result = body.status === "done" && body.result !== undefined ? text(body.result, LIMITS.result, "result", 0) : null;
    const error = body.status === "error" && body.error !== undefined ? text(body.error, LIMITS.error, "error", 0) : null;

    if (job.status === "done" || job.status === "error") {
      if (job.status === body.status && job.result === result && job.error === error) {
        return [200, { job: publicJob(job), idempotent: true }];
      }
      throw new HttpError(409, `The job is already ${job.status}.`);
    }
    const next = { ...job, status: body.status, result, error, updatedAt: now().toISOString() };
    await store.put(next);
    return [200, { job: publicJob(next) }];
  }

  /** @param {import("node:http").IncomingMessage} request */
  async function route(request) {
    const url = new URL(request.url ?? "/", "http://localhost");
    const parts = url.pathname.split("/").filter(Boolean);
    const method = request.method ?? "GET";
    if (parts[0] !== "jobs" || parts.length > 3) throw new HttpError(404, "Not found.");
    if (parts.length === 1) {
      if (method === "POST") return ["POST /jobs", await register(request)];
      if (method === "GET") return ["GET /jobs", list(request, url)];
      throw new HttpError(405, "Method not allowed.");
    }
    const id = parts[1];
    if (!ID.test(id)) throw new HttpError(404, "Not found.");
    if (parts.length === 2) {
      if (method === "GET") return ["GET /jobs/:id", read(request, id)];
      throw new HttpError(405, "Method not allowed.");
    }
    if (parts[2] !== "result") throw new HttpError(404, "Not found.");
    if (method === "POST") return ["POST /jobs/:id/result", await report(request, id)];
    throw new HttpError(405, "Method not allowed.");
  }

  const server = createServer(async (request, response) => {
    let name = `${request.method} ?`;
    let status = 500;
    let body = { error: "Something went wrong." };
    try {
      const [routeName, [code, payload]] = await route(request);
      name = routeName;
      status = code;
      body = payload;
    } catch (error) {
      if (error instanceof HttpError) {
        status = error.status;
        body = { error: error.message };
      } else {
        log(`grok-jobs: ${error instanceof Error ? error.name : "error"} handling a request`);
      }
    }
    const data = JSON.stringify(body);
    response.writeHead(status, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": Buffer.byteLength(data),
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...(status === 413 || status === 415 ? { Connection: "close" } : {}),
    });
    response.end(data);
    // The route's shape and the status: never an id, a header or a body.
    log(`${name} ${status}`);
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 50;

  return {
    store,
    server,
    /** @param {number} [port] */
    listen(port = options.port ?? 8789) {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          const address = server.address();
          const bound = typeof address === "object" && address ? address.port : port;
          if (!publicUrl) publicUrl = `http://${host.includes(":") ? `[${host}]` : host}:${bound}`;
          resolve({ port: bound, url: `http://${host.includes(":") ? `[${host}]` : host}:${bound}`, publicUrl });
        });
      });
    },
    close() {
      return new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve(undefined));
      }).then(() => store.writing);
    },
  };
}
