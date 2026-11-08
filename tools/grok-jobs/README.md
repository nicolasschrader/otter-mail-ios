# grok-jobs

The job service behind the iPhone app's **Give to Grok**: it registers a job for the app, hands
back a callback token made for that job alone (kept only as a SHA-256 hash), and takes the bot's
`running`, `done` or `error` on that callback. It never fetches a URL, runs nothing a bot says,
and listens on the loopback only. Putting it on the internet (Tailscale Funnel, a tunnel) is a
separate step of your own.

No dependencies; Node 20 or later.

## Run it

```sh
# A token of 32 characters or more, kept in a file outside the repository.
openssl rand -base64 48 > ~/.otter-mail/grok-jobs/app-token
chmod 600 ~/.otter-mail/grok-jobs/app-token

GROK_JOBS_APP_TOKEN_FILE=~/.otter-mail/grok-jobs/app-token \
GROK_JOBS_PUBLIC_URL=https://jobs.example.ts.net \
node tools/grok-jobs/bin/grok-jobs.mjs
```

| Variable                                          | Default                               |
| ------------------------------------------------- | ------------------------------------- |
| `GROK_JOBS_APP_TOKEN_FILE` / `GROK_JOBS_APP_TOKEN` | required (the file is preferred)      |
| `GROK_JOBS_PUBLIC_URL`                            | the local address (for the mock bot)  |
| `GROK_JOBS_PORT`                                  | `8789`                                |
| `GROK_JOBS_HOST`                                  | `127.0.0.1` (loopback only)           |
| `GROK_JOBS_DATA`                                  | `~/.otter-mail/grok-jobs/jobs.json`   |

The log has each request's route and status, never an id, a header or a body. The data file
(mode 0600) holds ids, statuses, results and hashes: no tokens, instructions or context.

In the iPhone app, Settings › Grok bot takes the webhook URL, the header and key the webhook
checks the sender by, this service's URL and the app token. They're kept in the Keychain, for
that device only, and never shown again (only the hosts).

## API

All bodies are JSON. The app authenticates with `Authorization: Bearer <app token>`.

- `POST /jobs` (app): `{ idempotencyKey, type: "task" | "mail" | "event", sourceKey,
  instruction, context }` → `201 { job, callback: { url, token }, replayed: false }`. The same
  key with the same job again answers `200 { job, replayed: true }` without a callback; with a
  different job, `409`. The context is at most 128 KB, the instruction 4000 characters.
- `GET /jobs/:id` (app) → `{ id, type, sourceKey, status, result, error, createdAt, updatedAt }`.
  `status` is `registered`, `running`, `done` or `error`.
- `GET /jobs?sourceKey=…` (app) → `{ jobs }`, the newest 50.
- `POST /jobs/:id/result` (the bot, `Authorization: Bearer <callback token>`): `{ status:
  "running" }`, `{ status: "done", result }` (at most 32,000 characters) or `{ status: "error",
  error }`. A finished job stays finished: the same report again is `200`, anything else `409`.

What the app posts to the webhook, after registering (with `Idempotency-Key: <job id>` and the
sender header from Settings):

```json
{
  "version": 1,
  "jobId": "…",
  "type": "mail",
  "instruction": "Draft a short reply saying yes.",
  "context": { "mail": { "subject": "…", "messages": [{ "from": "…", "text": "…" }] } },
  "callback": { "url": "https://…/jobs/…/result", "token": "…", "statuses": ["running", "done", "error"] }
}
```

The app shows exactly this context before Send. The bot's answer is shown as plain text and
never acted on.

## Try it locally

The mock bot takes the webhook payload when the sender header matches, answers 202, then reports
`running` and `done` (or `error`) to the callback. It only calls back to loopback addresses.

```sh
GROK_JOBS_APP_TOKEN=$(openssl rand -hex 24) node tools/grok-jobs/bin/grok-jobs.mjs
MOCK_BOT_SENDER_KEY="Bearer local-test" node tools/grok-jobs/mock-bot.mjs   # MOCK_BOT_OUTCOME=error
```

In the simulator, set the webhook to `http://127.0.0.1:8790/`, the sender key to
`Bearer local-test`, the job service to `http://127.0.0.1:8789` and the token you generated.

```sh
node --test tools/grok-jobs/test/
```
