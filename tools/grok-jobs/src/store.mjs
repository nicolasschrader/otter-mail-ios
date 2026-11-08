import { mkdir, readFile, rename, writeFile, chmod, rm } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { dirname } from "node:path";

/**
 * The jobs, in memory and in one JSON file: each change is written to a
 * temporary file (mode 0600) and renamed over the last one, one write at a
 * time, so the file is always a whole version. A file that can't be read is
 * an error at start, never written over.
 */
export class JobStore {
  /** @param {string} file */
  constructor(file) {
    this.file = file;
    /** @type {Map<string, Job>} */
    this.jobs = new Map();
    /** @type {Promise<void>} */
    this.writing = Promise.resolve();
  }

  async load() {
    let text;
    try {
      text = await readFile(this.file, "utf8");
    } catch (error) {
      if (/** @type {NodeJS.ErrnoException} */ (error).code === "ENOENT") return;
      throw error;
    }
    const parsed = JSON.parse(text);
    if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.jobs)) {
      throw new Error(`${this.file} isn't a grok-jobs file; it was left as it is.`);
    }
    for (const job of parsed.jobs) this.jobs.set(job.id, job);
    await chmod(this.file, 0o600);
  }

  /** @param {string} id */
  get(id) {
    return this.jobs.get(id);
  }

  /** @param {string} key */
  byIdempotencyKey(key) {
    for (const job of this.jobs.values()) if (job.idempotencyKey === key) return job;
    return undefined;
  }

  all() {
    return [...this.jobs.values()];
  }

  /** @param {Job} job */
  put(job) {
    this.jobs.set(job.id, job);
    return this.save();
  }

  /** @param {string[]} ids */
  remove(ids) {
    for (const id of ids) this.jobs.delete(id);
    return this.save();
  }

  save() {
    const data = JSON.stringify({ version: 1, jobs: this.all() });
    const next = this.writing.then(() => this.write(data));
    // A failed write fails its own caller; the next write still runs.
    this.writing = next.catch(() => {});
    return next;
  }

  /** @param {string} data */
  async write(data) {
    await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
    const temporary = `${this.file}.${randomBytes(6).toString("hex")}.tmp`;
    try {
      await writeFile(temporary, data, { mode: 0o600, flag: "wx" });
      await rename(temporary, this.file);
    } catch (error) {
      await rm(temporary, { force: true });
      throw error;
    }
  }
}

/**
 * @typedef {{
 *   id: string,
 *   idempotencyKey: string,
 *   type: "task" | "mail" | "event",
 *   sourceKey: string,
 *   instructionSha256: string,
 *   contextSha256: string,
 *   contextBytes: number,
 *   callbackSha256: string,
 *   status: "registered" | "running" | "done" | "error",
 *   result: string | null,
 *   error: string | null,
 *   createdAt: string,
 *   updatedAt: string,
 * }} Job
 */
