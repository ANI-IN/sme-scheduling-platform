# n8n workflows

Six workflows connect the database (Supabase) to Discord, Gmail and Google Drive. They hold **no business rules and
no domain, module or instructor names**. Every decision is made by database functions: n8n only calls them, sends the
messages they queue, reports the result back, serves the answer pages they render and passes typed replies to them.

They run on the owner's n8n Cloud Pro plan at `https://your-instance.app.n8n.cloud`: 10,000 executions a month,
shared with the other workflows in the same n8n account.

Every credential and setting, with its value where it is not a secret, is in docs/CONFIGURATION.md.

## The workflows

The live workflows are named `[Production] WF1 Hourly engine` to `[Production] WF6 Discord checks`. The database clock
was switched on at 17:36 UTC on 22 November 2026 (decision 281). While it runs its first 24 hours, the schedule
triggers of WF1 and WF4 stay on as a safety net. After 23 November 2026, 17:36 UTC, the owner's plan is to switch
those two schedule triggers off. Until that is done in n8n, the "before" column is what runs.

| File | Workflow | Trigger | Before 23 November, 12:48 UTC | Since 23 November, 12:48 UTC | What it does |
|---|---|---|---|---|---|
| `WF1-hourly-engine.json` | WF1 Hourly engine | Schedule trigger "Every hour" (minute 0) | Every hour at minute 0. The database clock also runs the same check at minute 30 | Unpublished, with its schedule trigger off (n8n cannot publish a workflow without a trigger): WF1 runs only when someone runs it by hand. The database's own hourly job runs the automatic check | Runs `engine_tick_all`, the automatic check for every domain. WF4 sends what it queues. WF1 does not poke WF4 and does not read replies |
| `WF2-response-handler.json` | WF2 Response handler | Webhook `GET` and `POST` `/webhook/sandbox-respond` | Whenever an instructor opens an answer link or presses the button on the page | Unchanged | Shows the answer page (`response_page`, records nothing), records the answer when the button on the page is pressed (`submit_response_page`), then pokes WF4 so the next messages go out at once |
| `WF3-daily-jobs.json` | WF3 Daily jobs | Schedule trigger "Every day 09:00" (Asia/Kolkata) | Every day at 09:00 IST | Unchanged | Runs `daily_jobs` (the daily system summary for the admin alert channel), pokes WF4 to send it, and saves the backup `sme-backup-YYYY-MM-DD.json` (`export_snapshot`) to Google Drive, keeping the newest 30 |
| `WF4-action-runner.json` | WF4 Action runner | Webhook `POST /webhook/sandbox-sme-poke` (a poke from the database) and schedule trigger "Every hour" | On every poke, and every hour | On every poke (the database pokes within seconds for every queued message and Discord check, and its clock every 2 minutes for other work), plus a safety run every hour | Runs app actions (`next_actions`, `complete_action`), delivers every queued Discord and Gmail message (`claim_outbound_messages`, `report_message_result`), runs the Discord checks people asked for (`next_discord_lookups`, `record_discord_result`) and reads typed replies by email and Discord. The only place messages are sent (decision 270) |
| `WF5-error-handler.json` | WF5 Error handler | n8n error trigger | When another workflow fails | Unchanged | The error workflow of WF1 to WF4. See [Error handling](#error-handling-wf5) |
| `WF6-discord-checks.json` | WF6 Discord checks | Schedule trigger "Every minute" | **Not published** | Unchanged: not published | WF4 does these checks now (decision 270). Kept as a spare: publish it only if WF4 cannot do them. It lists the servers the bot is in, checks a domain's server and its channels, and finds people by Discord username. It never creates servers or channels |

### How WF4 reads typed replies

- **Email.** WF4 reads only mail sent to the +scheduling reply address (every system email carries it as its Reply To
  address), and bounces of emails the app sent (they quote that address), from the last 3 days. The rest of the shared
  inbox is never touched. **Classify emails** only parses: a bounce goes to `record_bounce`, anything else to
  `record_inbound_message`. Since decision 311 a bounce counts only when it is in the Gmail thread of an email the app
  sent to that address; any other "bounce" is logged as "Bounce ignored" in Activity history and changes nothing. The
  files in `n8n/sandbox/` have this change; the live WF4 gets it with the batch 2 deploy (docs/PROGRESS.md).
- **Labels, not read marks.** Each mail the database accepted gets the Gmail label **SME Scheduling/Processed**.
  Nothing is marked as read, so people can still use the inbox as usual. A mail the database did not accept keeps no
  label and is tried again at the next run.
- **Discord.** WF4 reads newer messages in the instructors' channels listed by `discord_watchlist()` (channels in
  approved servers, for instructors with an open request, an upcoming class or an open help request). Only messages
  written by that channel's instructor are recorded, oldest first. The first time a channel is read, only messages
  from the last 3 days are recorded. Reading needs the bot's Message Content Intent.
- **How fast.** A typed reply shows in the app, in **Needs your attention**, within about 10 minutes while a
  conversation is open (the app sent that instructor something in the last 3 days). Otherwise it is read at WF4's next
  run.

## The database clock and pokes

A **poke** is a `POST` to WF4's webhook with the header `x-poke-key`. It carries no data; it only tells WF4 "there is
work in the database, do it now".

Since 22 November 2026, 17:36 UTC, the database keeps the clock (Release 3, M1, decision 281). `pg_cron` in Supabase
runs two jobs:

| Job | When | What it does |
|---|---|---|
| `sme-engine-hourly` | Every hour at minute 30 | Runs the automatic check (`engine_tick_all`) inside the database, as WF1 does |
| `sme-clock` | Every 2 minutes | Pokes WF4 through `pg_net` only when there is work: a message waiting to be sent, a queued app action, a queued Discord check, or an open conversation whose replies were last read 10 minutes ago or more. At most one poke a minute |

Reading replies follows the n8n runs the app counted this month (UTC):

| n8n runs this month | Replies read while a conversation is open |
|---|---|
| Under 5,000 | About every 10 minutes |
| 5,000 to 6,499 | About every 30 minutes; immediate calls at most one a minute |
| 6,500 to 7,999 | About every hour; calls at most one every 5 minutes |
| 8,000 and more | The clock no longer pokes for replies and calls at most every 10 minutes. Replies are still read whenever WF4 runs, and messages still go out |

When the count reaches 5,000, Activity history records "n8n budget: replies read less often" once that month.

The clock needs the WF4 poke address in the database and the poke key in Supabase Vault (secret `n8n_poke_key`, the
same value as the `Poke Secret Sandbox` credential). The app's buttons, WF2, WF3 and WF5 also poke WF4, so their
messages go out within seconds.

```bash
npm run clock -w scripts -- status
npm run clock -w scripts -- on https://<your n8n>/webhook/sandbox-sme-poke
npm run clock -w scripts -- off
```

`status` only reads: whether the clock is on, both jobs, whether the poke key is in Vault (yes or no only, never the
value), the last poke and its result, and the n8n runs this month by workflow.

**If the clock is switched off** (`npm run clock -w scripts -- off`), n8n no longer gets the clock's pokes and the
automatic check no longer runs in the database. Turn the schedule triggers of WF1 and WF4 back on and publish both
workflows again at once, so n8n works on its own schedule.

## Credentials

The workflows look credentials up by these exact names (decision 264). The names keep the word Sandbox on purpose:
they are internal names of the one live set, not a second environment. All five exist in the live n8n.

| Name | Type | Used by | What for |
|---|---|---|---|
| `Gmail Sandbox` | Gmail OAuth2 API, with n8n's own **Sign in with Google** | WF4 | Sends every email from the scheduling mailbox, reads the replies and bounces, adds the Processed label |
| `Discord Bot Sandbox` | Discord Bot API (the bot token) | WF4, WF5, WF6 | Posts, direct messages, reading replies, the server and username checks, WF5's fallback alert |
| `Google Drive Backups` | Google Drive OAuth2 API, with n8n's own **Sign in with Google** | WF3 | Uploads the nightly backup and moves backups older than the newest 30 to the Drive bin |
| `Supabase Sandbox` | Header Auth: name `apikey`, value the Supabase secret key (`sb_secret_…`) | All six | Every database call. Do not add an `Authorization: Bearer` header. This key bypasses row level security, so keep it private |
| `Poke Secret Sandbox` | Header Auth: name `x-poke-key`, value a long random string | WF4's poke webhook | Refuses any poke without the right key |

No Google Cloud Console is needed: n8n Cloud signs in to Gmail and Google Drive itself, with its own "Sign in with
Google". There is no Gmail or Drive client ID, client secret, refresh token or service account.

The bot needs only View Channels, Send Messages, Embed Links and Read Message History, plus the Server Members Intent
(username searches) and the Message Content Intent (typed replies). Both are on.

An optional `OpenAI Sandbox` credential is not created. The note "Optional AI summary" in WF4 shows where an OpenAI
node could add a one line `p_summary` to typed email replies. AI never decides anything.

## The Config node

Every workflow starts with a **Config** Code node. It is the only node you change by hand.

| Setting | Workflows | What it is |
|---|---|---|
| `supabaseUrl` | WF1 to WF6 | The Supabase project address |
| `pokeUrl` | WF1 to WF5 | WF4's poke webhook (production URL; no workflow calls it since 25 November 2026, the database does) |
| `adminChannelId` | WF5 | The admin Discord channel, used when the database cannot be reached |

The export fills them in, so nothing in a Config node needs setting by hand. The poke key is in no Config node: the
database sends it from Vault, and WF4's poke webhook checks it with the `Poke Secret Sandbox` credential (Header Auth,
name `x-poke-key`, decision 316). Never write its value in a file, a doc or a chat.

The export also fills in two values outside the Config node: the backup folder (WF3, **Upload to Google Drive** and
**List backups**) and the Gmail label ID of "SME Scheduling/Processed" (WF4, **Label as processed**). The +scheduling
reply address is written in WF4's base file itself (**Send email**, **Get system replies** and **Classify emails**).

## Changing a workflow

There is one workflow set: `n8n/sandbox/` holds the exported copies of the live workflows (the folder keeps its old
name). The second set, `n8n/production/`, and its generator option were removed on 23 November 2026 (decision 315),
because nothing used them.

The files in this folder (`n8n/WF*.json`) are the **base** files. Never import them, and never edit the exported files
by hand.

1. Change the base file in `n8n/`.
2. Build the exported files:

   ```bash
   npm run n8n-export -w scripts
   ```

   It writes `n8n/sandbox/`: it names each workflow `[Production] …`, adds the tag `Sandbox`, sets the credential names
   above, puts `sandbox-` in front of the webhook paths and fills in the addresses.
3. Update the live workflow in n8n: open it, select every node and delete them, then the **…** menu (top right),
   **Import from File…**, and choose the file from `n8n/sandbox/`. This keeps the workflow, its settings and its
   history. A new setup imports each file as a new workflow instead, **WF5 first** (the others point to it).
4. Open every node with a red credential warning and choose the credential with the same name (n8n usually matches
   them by itself).
5. Nothing to set in the Config node: the export fills it in, and the poke key comes from its credential.
6. If the schedule trigger of WF1 or WF4 is switched off in the live workflow, switch it off again in the imported
   copy: the base files still have both triggers.
7. Check the error workflow: the **…** menu, **Settings**, **Error workflow** = **[Production] WF5 Error handler**, for
   WF1 to WF4. WF5 has none.
8. **Publish** (the button at the top). Only published workflows run on schedule and answer their production
   webhooks. Publish WF5 and WF4 first. Leave WF6 unpublished.
9. Run the workflow once and check its execution (see [Checking runs](#checking-runs-and-the-monthly-count)).

n8n keeps every workflow's earlier versions. To roll back, open the version history, restore the previous version and
publish it.

## Webhook paths

The paths keep the word sandbox on purpose: links in messages already sent use them.

| Workflow | Method | Production URL | Protection | Where it is set |
|---|---|---|---|---|
| WF2 | `GET` | `https://your-instance.app.n8n.cloud/webhook/sandbox-respond?t=<token>` | None; **Ignore Bots** is on, so link preview bots get no page | `RESPONSE_BASE_URL` in `.env.production`, written into the database by `npm run configure:production -w scripts` (docs/SETUP_GUIDE.md, 1.4). The app shows it read only on Settings, Connections, Advanced: links |
| WF2 | `POST` | `https://your-instance.app.n8n.cloud/webhook/sandbox-respond` | None; the form on the answer page posts here | The same |
| WF4 | `POST` | `https://your-instance.app.n8n.cloud/webhook/sandbox-sme-poke` | Header `x-poke-key` (`Poke Secret Sandbox`); browsers only from `https://your-app.vercel.app` (Allowed Origins) | The app's `VITE_N8N_POKE_URL` and `VITE_N8N_POKE_KEY` (Vercel), the Poke WF4 nodes of WF2, WF3 and WF5 (the credential), and the database clock (`npm run clock -w scripts -- on <address>`, the key in Vault) |

The test URLs (`/webhook-test/...`) work only while you press "Listen for test event" in n8n. Never put a test URL in
the app or the database.

The app sends the poke as a normal (CORS) `fetch` with the `x-poke-key` header; in `no-cors` mode the browser drops
the header and n8n refuses the poke (403). The poke key can be seen by anyone who loads the app, which is acceptable:
a poke carries no data and only makes n8n do work that is already in the database. To limit who can poke from a
browser, change **Allowed Origins (CORS)** in WF4's **Poke webhook** node from `*` to the app's address.

## Error handling (WF5)

WF5 is the **Error workflow** of WF1 to WF4. When one of them fails:

1. `log_system_error` records the failure in Activity history and queues an alert for the admin alert channel.
2. WF5 pokes WF4, so the alert goes out at once.
3. If the database cannot be reached, WF5 posts the error straight to the admin alert channel with the bot.

Inside the workflows:

- Most database and Discord calls continue on error and report the problem instead of stopping the run. WF4 reports
  every claimed message back, failed or not.
- WF2 shows a friendly error page (HTTP 503) if the database cannot be reached and marks its run failed, so WF5
  alerts the admin. Nothing is retried; the instructor can press the button again.
- WF3 runs every step even if one fails, then fails its run at the end if anything went wrong, so WF5 alerts the
  admin.
- WF4 logs a problem reading Gmail or Discord with `log_system_error` ("Inbound reading failed at …").

## Checking runs and the monthly count

- **One workflow's runs:** in n8n, open the workflow, **Executions**. Each run shows its trigger, its result and every
  node's data.
- **The clock:** `npm run clock -w scripts -- status` shows the last poke, its reason (for example "messages to
  send" or "reading replies") and its result ("sent", or why not).
- **The monthly count, as the app counts it:** Settings, Connections, **Usage** (admins), or the `status` command
  above. The app counts each run from the first database call a workflow makes, per workflow and month (UTC), only
  for calls made by n8n (`n8n_usage`). The jobs the database runs itself are not n8n runs and are not counted.
- **The monthly count, as n8n counts it:** the n8n Cloud dashboard, **Usage**. It can be higher than the app's count,
  because the 10,000 are shared with the other workflows in the same n8n account.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| Messages stay waiting to send | Messages are paused, the clock is off or cannot poke, or WF4 is not published | Check for the red paused bar in the app. Run `npm run clock -w scripts -- status`: the last result says why a poke did not go ("no poke key in Vault", "no poke address", "no pg_net"). Check that WF4 is published and its last executions succeeded. Run WF4 by hand once |
| WF4 refuses pokes (403) | The `x-poke-key` value differs between the caller and `Poke Secret Sandbox` | Check that the app's `VITE_N8N_POKE_KEY` and the Vault secret `n8n_poke_key` hold the credential's value, and that the Poke WF4 nodes use the `Poke Secret Sandbox` credential. A poke from a browser on another site is refused by Allowed Origins on purpose |
| The automatic check on Settings, Connections is old | The clock is off, or the Supabase project is paused | Run `npm run clock -w scripts -- status`. If the clock is off and WF1's schedule trigger is off too, nothing runs the check: switch the clock on, or turn WF1's schedule trigger back on and publish |
| A typed reply does not show in Needs your attention | No conversation is open, reply reading slowed down, or the reply went elsewhere | Replies are read within about 10 minutes only while the app sent that instructor something in the last 3 days, and less often above 8,000 runs a month. Email replies count only when sent to the +scheduling address; Discord replies only in the instructor's own channel in an approved server, written by that instructor. Run WF4 by hand to read at once |
| A bounce changed nothing | It was not in the Gmail thread of an email the app sent to that address (decision 311) | Activity history says "Bounce ignored". This is on purpose: a fake "Undeliverable" email cannot mark an address as broken |
| The button on an answer page does nothing | The answer page link is the test URL, or WF2 is not published | Use `/webhook/sandbox-respond` in `RESPONSE_BASE_URL`, run configure again, and publish WF2 |
| A workflow failed | Any error | The admin alert channel and Activity history have the error from WF5. Open the execution in n8n to see which node failed |
| A node shows a red credential warning after an import | The credential was not matched by name | Choose the credential with the same name from the list |
| The monthly count is close to 10,000 | Too many runs, from these or other workflows in the account | Check Usage in the app and on the n8n dashboard. Reply reading and calls slow down by themselves from 5,000. Make sure WF6 is unpublished and the schedule triggers of WF1 and WF4 are off while the clock runs |

## Good to know

- **Message delivery.** WF4 claims up to 25 messages per run, sends each on its one channel and reports every claimed
  row back. 4xx errors (except 429) are permanent (for example Discord "Missing Access" or "Unknown Channel", or an
  invalid email address); everything else is temporary. The database tries temporary failures again (up to 3 attempts)
  and raises tasks. More than 25 waiting go at the next run. A message stuck in "Sending" (for example after n8n
  restarted during a send) becomes "Check needed" after 15 minutes: the team chooses Send again or It arrived (decision 341).
- **Discord rate limits.** WF4 waits 1 second after each Discord send and reads channels 2 per second.
- **Branch order.** All workflows use execution order v1: branches run top to bottom, one after another. WF4 relies on
  it (it marks actions Done only after delivery), so keep the layout if you move nodes.
- **Time zone.** WF3's workflow time zone is Asia/Kolkata, so 09:00 means 09:00 IST.
- **Answer pages.** `response_page` and `submit_response_page` return the Postgres domain type `"text/html"`, so
  Supabase answers with raw HTML when asked with `Accept: text/html`, and WF2 passes it straight through. Only the
  secret key may call them; the app's publishable key gets "permission denied". n8n serves the page with a sandboxing
  Content Security Policy that still allows forms, so the button (a plain HTML form) works without changing any n8n
  setting. Opening a link (`GET`) never records anything; only pressing the button (`POST`) does.

## Checking everything without credentials (mock mode)

From the repository root, with the local database running (`npm run db:start`):

```bash
npm run mock -- --race
```

This runs the real engine through a full class week timeline (setup check, request to teach, reminder about the
request, moving on, a No, a Yes, reminders before class, Need help, Can't make it), prints every message n8n would
send on each channel, plays the answer page `GET` and `POST` exactly as WF2 does, and finally presses the same "Yes"
link from two database connections at once to show that only one booking is created. The timeline runs inside a
transaction that is rolled back.
