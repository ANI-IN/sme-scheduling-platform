# n8n workflows

These six workflows connect the database (Supabase) to Discord, Gmail and Google Drive.
They contain **no business rules and no domain, module or instructor names**. Every decision is made by
database functions; n8n only calls them, sends the messages they queue, reports the result back,
serves the pages they render and passes inbound replies to them.

| File | Workflow | Trigger | What it does |
|---|---|---|---|
| `WF1-hourly-engine.json` | WF1 Hourly engine | Every hour | Runs `engine_tick_all` (all checks for all domains). WF4 delivers what it queues within 6 minutes. |
| `WF2-response-handler.json` | WF2 Response handler | Webhook `GET` and `POST` `/webhook/respond` | Shows the confirm page (`response_page`), records the answer when the button on the page is pressed (`submit_response_page`), then pokes WF4. |
| `WF3-daily-jobs.json` | WF3 Daily jobs | Every day 09:00 IST | Runs `daily_jobs` (heartbeat), pokes WF4, exports a backup (`export_snapshot`) to Google Drive as `sme-backup-YYYY-MM-DD.json`. |
| `WF4-action-runner.json` | WF4 Action runner (the heartbeat) | Webhook `POST /webhook/sme-poke` and every 6 minutes | Processes app actions (`next_actions` / `complete_action`) and **delivers all queued messages** by Discord and Gmail (`claim_outbound_messages` / `report_message_result`); runs the Discord checks people asked for (`next_discord_lookups` / `record_discord_result`); reads typed replies: Gmail replies to the +scheduling address and bounces, and the instructors' Discord channels. This is the only place messages are sent (decision 270). |
| `WF6-discord-checks.json` | WF6 Discord checks (**not published**) | None: WF4 does this now (decision 270). Publish only if WF4 cannot. | Takes the Discord checks people asked for in the app (`next_discord_lookups`): lists the servers the bot is in, checks a domain's server and its channels, and finds people by Discord username (member search). Saves the raw answers with `record_discord_result`; the database decides what they mean. Never creates servers or channels. |
| `WF5-error-handler.json` | WF5 Error handler | n8n error trigger | Records any workflow failure in History (`log_system_error`, which also queues an admin alert) and pokes WF4 so the alert goes out. If the database can't be reached, posts straight to the admin Discord channel. |

"Poke" = an empty `POST` to the WF4 webhook with the header `x-poke-key`. It carries no data; it only tells
WF4 "there is work in the database, process it now". WF4 also runs every 6 minutes, so nothing is lost if a poke fails.

## The Production workflows and the two folders

There is one environment, **Production** (since 22 November 2026). It is the old Sandbox under a new name, in the same
n8n instance, and there is no Sandbox any more. The live workflows are named `[Production] WF1 Hourly engine`,
`[Production] WF2 Response handler`, `[Production] WF3 Daily jobs`, `[Production] WF4 Action runner`,
`[Production] WF5 Error handler` and `[Production] WF6 Discord checks`.

Some internal names keep the word Sandbox on purpose, because renaming them could break things. They are internal
names only, not a second environment: the credential names, the tag `Sandbox`, the webhook paths
`/webhook/sandbox-respond` and `/webhook/sandbox-sme-poke`, and the folder `n8n/sandbox/`.

The files in this folder are the **base** workflows. Do not import them directly. Run

```bash
npm run n8n-export -w scripts
```

to build the two exported sets:

- **`n8n/sandbox/`** holds the exported copies of the live Production workflows. The folder keeps its old name.
- **`n8n/production/`** holds older templates for a separate Production setup that was not used. Do not import them
  into the live n8n.

| | `n8n/sandbox/` (live Production) | `n8n/production/` (not used) |
|---|---|---|
| Workflow names | `[Production] WF1 Hourly engine` and so on | `[Production] WF1 Hourly engine` and so on |
| Tag | `Sandbox` (internal name, kept on purpose) | `Production` |
| Credential names | `Gmail Sandbox`, `Discord Bot Sandbox`, `Google Drive Backups`, `Supabase Sandbox`, `Poke Secret Sandbox` (kept on purpose) | The same with `Production` |
| WF2 webhook | `/webhook/sandbox-respond` (kept: links in messages already sent use it) | `/webhook/respond` |
| WF4 webhook | `/webhook/sandbox-sme-poke` (kept) | `/webhook/sme-poke` |
| Config values | Filled in: the Production Supabase and n8n addresses | `https://YOUR-PRODUCTION-PROJECT.supabase.co` to replace |

Only the `n8n/sandbox/` set runs. It talks to the Production Supabase project, the bot behind `Discord Bot Sandbox`
and the B2C mailbox. Change the base files, then export again; never edit the exported files by hand.

### Every credential and variable

See docs/CONFIGURATION.md: one table of every value, where it goes, and the Production value where it is known.

## 1. Before you start

You need:

1. The Supabase project URL, for example `https://abcdefgh.supabase.co`.
2. Admin access to the company Discord server.
3. A Google Workspace account for the dedicated scheduling mailbox (for example `scheduling@…`), and access to Google Cloud Console.
4. A Google Drive folder for the nightly backups (Production: `your-drive-folder-id`).
5. Your n8n address, for example `https://n8n.yourcompany.com` (written as `https://<your-n8n>` below).

## 2. Create the credentials

In n8n: **Overview → Credentials → Create credential**. The workflows look credentials up by these exact names
(decision 264). Production keeps the internal Sandbox credential names and already has three of them; you only create the other two.

| Name (Production) | Name (separate setup, not used) | Type | State in Production |
|---|---|---|---|
| `Gmail Sandbox` | `Gmail Production` | Gmail OAuth2 API, with n8n's own **Sign in with Google** | Done: the B2C mailbox |
| `Discord Bot Sandbox` | `Discord Bot Production` | Discord Bot API (the bot token) | Done |
| `Google Drive Backups` | `Google Drive Backups Production` | Google Drive OAuth2 API, with n8n's own **Sign in with Google** | Done |
| `Supabase Sandbox` | `Supabase Production` | Header Auth | To create (2.1) |
| `Poke Secret Sandbox` | `Poke Secret Production` | Header Auth | To create (2.2) |

No Google Cloud OAuth client, client secret, refresh token or service account is needed: n8n Cloud signs in to Gmail
and Google Drive itself.

### 2.1 "Supabase Sandbox" (Header Auth)

1. In Supabase: **Project Settings → API Keys → Secret keys**. Create one named `n8n`, or copy the existing
   `sb_secret_…` key.
2. In n8n create a credential of type **Header Auth**, name `Supabase Sandbox`.
3. Header **Name**: `apikey`. Header **Value**: the `sb_secret_…` key.
4. Do **not** add an `Authorization: Bearer` header. The new Supabase keys only go in the `apikey` header.

Keep this key private: it bypasses all row level security.

### 2.2 "Poke Secret Sandbox" (Header Auth)

1. Make a long random string (for example from your password manager).
2. In n8n create a credential of type **Header Auth**, name `Poke Secret Sandbox`, header **Name** `x-poke-key`,
   header **Value** the random string.
3. Keep the string: it also goes in every Config node (`pokeKey`, step 4) and in the app (`VITE_N8N_POKE_KEY`).

### 2.3 What the existing credentials are used for

- **Discord Bot Sandbox**: every call to Discord (posts, direct messages, reading replies, the server and username
  checks). The bot needs only View Channels, Send Messages, Embed Links and Read Message History, and the
  Server Members Intent and Message Content Intent switched on (both are on).
- **Gmail Sandbox**: sends every email from the B2C mailbox and reads the replies to it.
- **Google Drive Backups**: WF3 uploads the nightly backup to the backup folder
  (`your-drive-folder-id`, already filled in) and moves backups older than the newest 30 to the
  Drive bin.

## 3. Import the workflows

Import from `n8n/sandbox/` (the Production workflows). `n8n/production/` is only for a separate new setup.
Import **WF5 first** (the others point to it as their error workflow), then the rest:

1. In n8n: **Overview → Create → Workflow** (or **Workflows → Add workflow**), then the **…** menu (top right) → **Import from File…**.
2. Choose `WF5-error-handler.json`. Save.
3. Repeat for `WF4-action-runner.json`, `WF2-response-handler.json`, `WF1-hourly-engine.json`, `WF3-daily-jobs.json` (one new workflow each). You may import `WF6-discord-checks.json` too, but leave it unpublished.
4. In each workflow, open every node that shows a red credential warning and pick the matching credential from the list
   (the imported files only carry the credential *names*; n8n usually matches them automatically).

## 4. Edit the Config node in every workflow

Every workflow starts with a **Config** Code node. In the `n8n/sandbox/` files the Supabase address
(`https://abcdefghijklmnopqrst.supabase.co`) and the WF4 address
(`https://your-instance.app.n8n.cloud/webhook/sandbox-sme-poke`) are already filled in. Only one value is left:

```js
const pokeKey = 'REPLACE_WITH_POKE_SECRET';   // the value of the "Poke Secret Sandbox" credential (step 2.2)
```

Do this in WF2 to WF5 (WF1 no longer pokes WF4).

WF3's backup folder is filled in too, in **Upload to Google Drive** and **List backups**. For a separate setup from
`n8n/production/`, replace
`REPLACE_WITH_PRODUCTION_DRIVE_FOLDER_ID` in both with the Production folder ID (the last part of the folder's address
in Drive: `https://drive.google.com/drive/folders/<this part>`), and the Supabase address in every Config node.

## 5. Set the error workflow

For **WF1, WF2, WF3 and WF4**: open the workflow → **…** menu → **Settings** → **Error workflow** → choose
**[Production] WF5 Error handler** → Save. (WF5 itself has no error workflow.)

## 6. Publish (activate) the workflows

1. Publish each workflow (n8n 2.x: the **Publish** button at the top; older versions: the **Active** toggle).
   Publish WF5 and WF4 first.
2. Only published workflows run on schedule and answer their **production** webhook URLs
   (`/webhook/...`). The **test** URLs (`/webhook-test/...`) only work while you click "Listen for test event".
3. Production URLs (open the webhook node → **Production URL** to copy them):
   - WF4: `https://<your-n8n>/webhook/sandbox-sme-poke` (Production; the path keeps its name) or
     `https://<your-n8n>/webhook/sme-poke` (separate setup)
   - WF2: `https://<your-n8n>/webhook/sandbox-respond` (Production; the path keeps its name) or
     `https://<your-n8n>/webhook/respond` (separate setup)

## 7. Tell the database and the app where n8n is

1. **Answer page link (WF2).** Every instructor button and the form on every answer page is built from it. Put
   the WF2 production address in `RESPONSE_BASE_URL` in `.env.production` (`/webhook/sandbox-respond` for
   Production), then run `npm run configure:production -w scripts` (docs/SETUP_GUIDE.md, 1.4). It must start with `https://`. The app shows
   it read only on **Settings, Connections, Advanced: links**; it cannot be changed from the app (decision 205).
2. **Poke URL and secret (WF4)**, in the app's environment (Vercel → your project → Settings → Environment Variables, and `app/.env.sandbox` when you run the app on your computer against Production):
   - `VITE_N8N_POKE_URL` = `https://<your-n8n>/webhook/sandbox-sme-poke` for Production (`/webhook/sme-poke` in a
     separate setup)
   - `VITE_N8N_POKE_KEY` = the Poke secret value
   - Redeploy the app after changing them.
   - The same URL and secret go in each workflow's **Config** node (step 4).
3. In the app, choose the **Admin alert channel** on **Settings, Connections, Discord servers** (from the list), so
   failure alerts and the daily system summary have somewhere to go.
4. The app must send the poke as a normal (CORS) `fetch` with the `x-poke-key` header. Browsers silently drop custom
   headers in `no-cors` mode, and n8n then rejects the poke (403). WF4 still delivers within 6 minutes, but not instantly.

Note: the poke key is visible to anyone who can load the app in a browser. That is acceptable because a poke carries no
data and can only make n8n process work that is already in the database. To limit who can call it from a browser,
change **Allowed Origins (CORS)** in WF4's **Poke webhook** node from `*` to the app's address.

## 8. Test it

1. On **Settings, Testing**, choose the testing channel and testing email, then press **Turn on testing** for a domain.
2. Press **Send test alert** on **Setup, Team** (a team alert), and **Send contact check** for a test instructor on
   **Setup, Instructors**. Within seconds a message should appear in Discord and the inbox. If not, check WF4's
   **Executions** list.
3. Press **Run the automatic check now** on **Settings, Testing**: WF4 runs the engine and sends anything due. While a
   domain is being tested, every instructor message goes to the testing channel and testing email, and says who it
   would have gone to.
4. Click a button in a test message: the confirm page opens (nothing is recorded yet). Press the button on the page:
   the answer is recorded and follow-up messages arrive within seconds.
5. Type a reply in a test instructor's Discord channel or reply to a test email; after the next hourly run (or run WF1
   manually with **Execute workflow**) it shows up in **Needs Attention**.
6. Run WF3 manually once and check that `sme-backup-YYYY-MM-DD.json` appears in the backup folder. Only the newest 30 backups are kept; older ones go to the Drive bin.
7. To test WF5, temporarily break the Supabase URL in WF1's Config and run WF1: an admin alert should arrive and a
   History entry should be recorded (put the URL back afterwards).

## 9. Good to know

- **Confirm pages and n8n's sandbox.** n8n serves HTML returned by a webhook with a sandboxing Content-Security-Policy.
  That sandbox allows forms, so the confirm page's button (a plain HTML form) works without changing any n8n
  environment variable. The form posts to the absolute `response_base_url`, which is why step 7.1 matters.
  The pages are mobile-friendly HTML produced by the database.
- **Link scanners.** Opening a link (GET) never records anything; only pressing the button on the page (POST) does.
  The GET webhook also has **Ignore Bots** on, so link-preview bots get no page at all.
- **Message delivery.** WF4 claims up to 25 messages per run, sends each one on its single channel, and reports every
  claimed row back. Failures are reported with the error text; 4xx errors (except 429) are marked permanent
  (for example Discord "Missing Access" / "Unknown Channel", invalid email address), everything else is temporary.
  The database re-queues temporary failures (up to 3 attempts) and raises alerts. If more than 25 are waiting,
  the rest go on the next poke or within 6 minutes. A row stuck in "Sending" (for example n8n restarted mid-send) is
  re-queued automatically by the database after 15 minutes.
- **Discord rate limits.** WF4 waits 1 second after each Discord send; WF1 reads channels 2 per second.
- **Discord replies.** Only channels returned by `discord_watchlist()` are read, and only messages written by that
  channel's instructor are recorded. The first time a channel is read, only messages from the last 3 days are recorded,
  so old chat history is not imported.
- **Email replies.** WF1 reads unread inbox mail from the last 3 days and marks it as read once the database has accepted it.
  Do not read the scheduling mailbox's inbox by hand in a way that marks mails read before the hourly run,
  or leave them unread.
- **Branch order.** All workflows use execution order v1: branches run top to bottom, one after another. Some workflows
  rely on that (for example WF4 marks actions Done only after delivery). Keep the layout if you move nodes.
- **Optional AI summary.** WF1 has a note showing where an OpenAI node could add a one-line `p_summary` to typed replies.
  AI never decides anything.
- **Timezones.** WF3's workflow timezone is set to Asia/Kolkata, so 09:00 means 09:00 IST regardless of the server timezone.
- **Why `Accept: text/html`.** `response_page` and `submit_response_page` return the Postgres domain type `"text/html"`,
  so Supabase (PostgREST) answers with raw HTML when asked with `Accept: text/html`. WF2 passes it straight through.
  These two functions can only be called with the secret key — the app's publishable key gets "permission denied".

## 10. Checking everything without credentials (mock mode)

From the repository root, with the local database running (`npm run db:start`):

```bash
npm run mock -- --race
```

This runs the real engine through a full module-week timeline (readiness → outreach → reminder → move on → decline →
Yes → check-ins → Need help → Can't make it), prints every message n8n would send on each channel, simulates the
confirm-page GET/POST exactly as WF2 does, and finally presses the same "Yes" link from two database connections at
once to show that only one booking is created. The timeline runs inside a transaction that is rolled back.
