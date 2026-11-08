import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { APP_TOKEN, registration, startService } from "./helpers.mjs";
import { createMockBot } from "../mock-bot.mjs";

test("registers a job and hands out its callback once", async (t) => {
  const service = await startService();
  t.after(() => service.stop());

  const first = await service.call("/jobs", { method: "POST", json: registration() });
  assert.equal(first.status, 201);
  assert.equal(first.body.job.status, "registered");
  assert.match(first.body.callback.url, new RegExp(`/jobs/${first.body.job.id}/result$`));
  assert.ok(first.body.callback.token.length >= 32);

  const replay = await service.call("/jobs", { method: "POST", json: registration() });
  assert.equal(replay.status, 200);
  assert.equal(replay.body.replayed, true);
  assert.equal(replay.body.job.id, first.body.job.id);
  assert.equal(replay.body.callback, undefined);

  const other = await service.call("/jobs", { method: "POST", json: registration({ instruction: "Something else." }) });
  assert.equal(other.status, 409);
});

test("keeps no token or context on disk, and the file private", async (t) => {
  const service = await startService();
  t.after(() => service.stop());
  const { body } = await service.call("/jobs", { method: "POST", json: registration() });
  await service.service.store.writing;

  const file = join(service.folder, "jobs.json");
  const text = await readFile(file, "utf8");
  assert.ok(!text.includes(body.callback.token));
  assert.ok(!text.includes("Say yes to dinner"));
  assert.ok(!text.includes(APP_TOKEN));
  assert.equal((await stat(file)).mode & 0o777, 0o600);
});

test("needs the app token for registering and reading", async (t) => {
  const service = await startService();
  t.after(() => service.stop());
  assert.equal((await service.call("/jobs", { method: "POST", json: registration(), token: null })).status, 401);
  assert.equal((await service.call("/jobs", { method: "POST", json: registration(), token: "wrong" })).status, 401);
  const { body } = await service.call("/jobs", { method: "POST", json: registration() });
  assert.equal((await service.call(`/jobs/${body.job.id}`, { token: "wrong" })).status, 401);
  assert.equal((await service.call(`/jobs/${body.job.id}`)).status, 200);
  assert.equal((await service.call("/jobs/unknown-id")).status, 404);
});

test("takes the bot's report on the job's own token only", async (t) => {
  const service = await startService();
  t.after(() => service.stop());
  const a = (await service.call("/jobs", { method: "POST", json: registration() })).body;
  const b = (
    await service.call("/jobs", {
      method: "POST",
      json: registration({ idempotencyKey: "second-key-123", sourceKey: "mail:me@example.com|t1", type: "mail" }),
    })
  ).body;
  const path = `/jobs/${a.job.id}/result`;

  assert.equal((await service.call(path, { method: "POST", json: { status: "done" }, token: APP_TOKEN })).status, 401);
  assert.equal((await service.call(path, { method: "POST", json: { status: "done" }, token: b.callback.token })).status, 401);
  assert.equal((await service.call(path, { method: "POST", json: { status: "nope" }, token: a.callback.token })).status, 400);

  const running = await service.call(path, { method: "POST", json: { status: "running" }, token: a.callback.token });
  assert.equal(running.body.job.status, "running");
  const done = await service.call(path, { method: "POST", json: { status: "done", result: "Drafted." }, token: a.callback.token });
  assert.equal(done.body.job.status, "done");

  const again = await service.call(path, { method: "POST", json: { status: "done", result: "Drafted." }, token: a.callback.token });
  assert.equal(again.status, 200);
  assert.equal(again.body.idempotent, true);
  const back = await service.call(path, { method: "POST", json: { status: "running" }, token: a.callback.token });
  assert.equal(back.status, 409);

  const read = await service.call(`/jobs/${a.job.id}`);
  assert.deepEqual([read.body.status, read.body.result], ["done", "Drafted."]);
  assert.equal(read.body.callbackSha256, undefined);
});

test("refuses what isn't JSON, too large, or malformed", async (t) => {
  const service = await startService();
  t.after(() => service.stop());
  const plain = await service.call("/jobs", { method: "POST", body: "{}", headers: { "Content-Type": "text/plain" } });
  assert.equal(plain.status, 415);
  const big = registration({ context: { mail: { text: "x".repeat(130 * 1024) } } });
  assert.equal((await service.call("/jobs", { method: "POST", json: big })).status, 413);
  assert.equal((await service.call("/jobs", { method: "POST", json: registration({ type: "shell" }) })).status, 400);
  assert.equal((await service.call("/jobs", { method: "POST", json: registration({ idempotencyKey: "a b" }) })).status, 400);
});

test("keeps jobs across a restart", async (t) => {
  const first = await startService();
  const { body } = await first.call("/jobs", { method: "POST", json: registration() });
  await first.stop({ keep: true });
  const second = await startService({ folder: first.folder });
  t.after(() => second.stop());
  assert.equal((await second.call(`/jobs/${body.job.id}`)).body.status, "registered");
});

test("listens on the loopback only, with a long app token", async () => {
  await assert.rejects(startService({ host: "0.0.0.0" }), /loopback/);
  await assert.rejects(startService({ appToken: "short" }), /32 characters/);
});

test("the mock bot runs a job end to end", async (t) => {
  const service = await startService();
  const bot = createMockBot({ senderKey: "Bearer sender-key", delayMs: 10 });
  const webhook = await bot.listen(0);
  t.after(async () => {
    await bot.close();
    await service.stop();
  });

  const { body } = await service.call("/jobs", { method: "POST", json: registration() });
  const payload = {
    version: 1,
    jobId: body.job.id,
    type: "task",
    instruction: "Draft a reply saying yes.",
    context: registration().context,
    callback: { ...body.callback, statuses: ["running", "done", "error"] },
  };
  const refused = await fetch(webhook, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer wrong" },
    body: JSON.stringify(payload),
  });
  assert.equal(refused.status, 401);
  const accepted = await fetch(webhook, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer sender-key" },
    body: JSON.stringify(payload),
  });
  assert.equal(accepted.status, 202);

  let job;
  for (let i = 0; i < 100; i++) {
    job = (await service.call(`/jobs/${body.job.id}`)).body;
    if (job.status === "done") break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(job.status, "done");
  assert.match(job.result, /^Mock bot: "Draft a reply saying yes\."/);
});
