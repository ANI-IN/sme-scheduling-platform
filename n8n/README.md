# n8n workflows

These six workflows connect the database (Supabase) to Discord, Gmail and Google Drive.
They contain **no business rules and no domain, module or instructor names**. Every decision is made by
database functions; n8n only calls them, sends the messages they queue, reports the result back,
serves the pages they render and passes inbound replies to them.

| File | Workflow | Trigger | What it does |
|---|---|---|---|
| `WF1-hourly-engine.json` | WF1 Hourly engine | Every hour | Runs `engine_tick_all` (all checks for all domains), reads Gmail replies and bounces and instructor Discord replies, then pokes WF4. |
| `WF2-response-handler.json` | WF2 Response handler | Webhook `GET` and `POST` `/webhook/respond` | Shows the confirm page (`response_page`), records the answer when the button on the page is pressed (`submit_response_page`), then pokes WF4. |
| `WF3-daily-jobs.json` | WF3 Daily jobs | Every day 09:00 IST | Runs `daily_jobs` (heartbeat), pokes WF4, exports a backup (`export_snapshot`) to Google Drive as `sme-backup-YYYY-MM-DD.json`. |
| `WF4-action-runner.json` | WF4 Action runner | Webhook `POST /webhook/sme-poke` and every 5 minutes | Processes app actions (`next_actions` / `complete_action`) and **delivers all queued messages** by Discord and Gmail (`claim_outbound_messages` / `report_message_result`). This is the only place messages are sent. |
| `WF6-discord-checks.json` | WF6 Discord checks | Every minute | Takes the Discord checks people asked for in the app (`next_discord_lookups`): lists the servers the bot is in, checks a domain's server and its channels, and finds people by Discord username (member search). Saves the raw answers with `record_discord_result`; the database decides what they mean. Never creates servers or channels. |
| `WF5-error-handler.json` | WF5 Error handler | n8n error trigger | Records any workflow failure in History (`log_system_error`, which also queues an admin alert) and pokes WF4 so the alert goes out. If the database can't be reached, posts straight to the admin Discord channel. |

"Poke" = an empty `POST` to the WF4 webhook with the header `x-poke-key`. It carries no data; it only tells
WF4 "there is work in the database, process it now". WF4 also runs every 5 minutes, so nothing is lost if a poke fails.

## Sandbox and Production

The files in this folder are the **base** workflows. Do not import them directly. Run

```bash
npm run n8n-export -w scripts
```

to build the two sets you import:

| | `n8n/sandbox/` | `n8n/production/` |
|---|---|---|
| Workflow names | `[Sandbox] WF1 Hourly engine` and so on | `[Production] WF1 Hourly engine` and so on |
| Tag | `Sandbox` | `Production` |
| Credential names | `Supabase secret key (Sandbox)` and so on | `Supabase secret key (Production)` and so on |
| WF2 webhook | `/webhook/sandbox-respond` | `/webhook/respond` |
| WF4 webhook | `/webhook/sandbox-sme-poke` | `/webhook/sme-poke` |
| Config placeholder | `https://YOUR-SANDBOX-PROJECT.supabase.co` | `https://YOUR-PRODUCTION-PROJECT.supabase.co` |

Because names, credentials and webhook paths differ, both sets can run in **one** n8n instance without touching
each other, or in two separate instances (better when you can afford it). Each set must only ever use its own
environment's credentials: the Sandbox set talks to the Sandbox Supabase project, the Sandbox Discord bot and the
Sandbox mailbox; the Production set to the Production ones. Change the base files, then export again; never edit
the exported files by hand.

### Every credential and variable, per environment

| What | Kind | Sandbox | Production |
|---|---|---|---|
| `Supabase secret key (<env>)` | n8n credential, Header Auth `apikey` | Sandbox project `sb_secret_…` | Production project `sb_secret_…` |
| `Discord bot (<env>)` | n8n credential, Header Auth `Authorization: Bot …` | Sandbox bot token (bot only in the test server) | Production bot token |
| `Gmail scheduling (<env>)` | n8n credential, Gmail OAuth2 | Sandbox mailbox, for example `scheduling-sandbox@…` | Real scheduling mailbox |
| `Google service account (<env>)` | n8n credential, Google Service Account | Can be the same service account | Production service account |
| `Poke secret (<env>)` | n8n credential, Header Auth `x-poke-key` | Its own random string | A different random string |
| `supabaseUrl` | Config node, all six workflows | Sandbox project URL | Production project URL |
| `pokeUrl` | Config node, all six workflows | `https://<your-n8n>/webhook/sandbox-sme-poke` | `https://<your-n8n>/webhook/sme-poke` |
| `pokeKey` | Config node, all six workflows | The Sandbox poke secret | The Production poke secret |
| Shared drive ID and folder ID | WF3 node "Upload to Google Drive" | A Sandbox backup folder | The Production backup folder |
| Error workflow | Settings of WF1 to WF4 and WF6 | `[Sandbox] WF5 Error handler` | `[Production] WF5 Error handler` |
| `response_base_url` | Database, app Settings | `https://<your-n8n>/webhook/sandbox-respond` | `https://<your-n8n>/webhook/respond` |
| `VITE_N8N_POKE_URL`, `VITE_N8N_POKE_KEY` | App hosting variables | Sandbox values | Production values |

The Sandbox database also refuses to send anything outside its allow lists (`SANDBOX_ALLOWED_DISCORD_SERVERS` and
`SANDBOX_ALLOWED_EMAIL_DOMAINS`, set with `npm run configure -w scripts`), and the Production database never messages
an instructor marked as a test instructor. These checks are in the database, so they hold even if a workflow is
pointed at the wrong place.

In the steps below, `(<env>)` means `(Sandbox)` or `(Production)`. Do the steps once per environment.

---

## 1. Before you start

You need:

1. The Supabase project URL, for example `https://abcdefgh.supabase.co`.
2. Admin access to the company Discord server.
3. A Google Workspace account for the dedicated scheduling mailbox (for example `scheduling@…`), and access to Google Cloud Console.
4. A Google Drive folder for the nightly backups.
5. Your n8n address, for example `https://n8n.yourcompany.com` (written as `https://<your-n8n>` below).

## 2. Create the credentials

In n8n: **Overview → Credentials → Create credential** (or the **+** menu → Credential). Use exactly these names,
with the environment at the end (for example `Supabase secret key (Sandbox)`), because the workflows look them up by name.

### 2.1 "Supabase secret key (<env>)" (Header Auth)

1. In Supabase: **Dashboard → Project Settings → API Keys → Secret keys**. Create one (for example "n8n") or copy the existing `sb_secret_…` key.
2. In n8n create a credential of type **Header Auth**.
3. Name: `Supabase secret key (Sandbox)` or `Supabase secret key (Production)`.
4. Header **Name**: `apikey`
5. Header **Value**: the `sb_secret_…` key.
6. Do **not** add an `Authorization: Bearer` header. The new Supabase keys only go in the `apikey` header.

Keep this key private: it bypasses all row-level security.

### 2.2 "Discord bot (<env>)" (Header Auth)

1. Go to <https://discord.com/developers/applications> → **New Application** (for example "SME Scheduling").
2. Open **Bot** → **Reset Token** → copy the token.
3. On the same **Bot** page, under **Privileged Gateway Intents**, switch on **SERVER MEMBERS INTENT** (WF6 finds
   people by their Discord username) and **MESSAGE CONTENT INTENT** (WF1 reads typed replies). Save.
4. Invite the bot with the link on the app's **Settings, Connections, Discord servers** (it needs `VITE_DISCORD_CLIENT_ID`,
   the Application ID). It asks for exactly **View Channels**, **Send Messages**, **Embed Links** and
   **Read Message History** (permissions value 84992). Add it to the server of each domain.
5. Give the bot's role the same four permissions on the instructors' `1-1` category and on the alert, admin and test
   channels (private channels need the bot added explicitly).
6. WF4 sends instructor messages to their channel in the class's domain, or by direct message when they have no
   channel there, and sends team members their own copies by direct message (or email when they have no Discord).
7. In n8n create a credential of type **Header Auth**:
   - Name: `Discord bot (Sandbox)` or `Discord bot (Production)`
   - Header **Name**: `Authorization`
   - Header **Value**: `Bot ` followed by the token (the word `Bot`, a space, then the token).

### 2.3 "Gmail scheduling (<env>)" (Gmail OAuth2)

1. In Google Cloud Console create (or pick) a project for the integration.
2. **APIs & Services → Library** → enable **Gmail API**.
3. **APIs & Services → OAuth consent screen** (Google Auth Platform → Branding/Audience): user type **Internal**, fill in the app name and support email.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID** → type **Web application**.
   Under **Authorized redirect URIs** add `https://<your-n8n>/rest/oauth2-credential/callback`
   (the n8n credential window shows this exact URL as "OAuth Redirect URL" — copy it from there).
5. Copy the **Client ID** and **Client secret**.
6. In n8n create a credential of type **Gmail OAuth2 API**, name `Gmail scheduling (Sandbox)` or `Gmail scheduling (Production)`, paste the Client ID and secret,
   click **Sign in with Google** and sign in **as the scheduling mailbox** (the address messages should come from and replies go to).

### 2.4 "Google service account (<env>)" (Google Service Account, for the backups)

The nightly backup is uploaded by a Google service account, so it keeps working when a person leaves.
A service account has no Drive storage of its own, so the backup folder must be in a **shared drive**.

1. In the same Google Cloud project: **APIs & Services → Library** → enable **Google Drive API**.
2. **IAM & Admin → Service Accounts → Create service account**, for example `sme-backup`. No roles are needed. Create.
3. Open it → **Keys → Add key → Create new key → JSON**. A file downloads. Keep it private; it works like a password.
4. In Google Drive create a shared drive (for example "Scheduling backups"), and in it one folder per environment.
   Add the service account's email (it ends in `iam.gserviceaccount.com`) to the shared drive as **Content manager**.
5. In n8n create a credential of type **Google Service Account API**, name `Google service account (Sandbox)` or
   `Google service account (Production)`. Paste the `client_email` and the `private_key` from the JSON file. Save.
6. Delete the downloaded JSON file once the credential is saved.

### 2.5 "Poke secret (<env>)" (Header Auth)

1. Make a long random string (for example from a password manager, or `openssl rand -hex 24`).
2. In n8n create a credential of type **Header Auth**:
   - Name: `Poke secret (Sandbox)` or `Poke secret (Production)` (a different string for each)
   - Header **Name**: `x-poke-key`
   - Header **Value**: the random string.
3. Keep the string: it also goes in every Config node (step 4) and in the app (step 7).

## 3. Import the workflows

Import from `n8n/sandbox/` for Sandbox and from `n8n/production/` for Production.
Import **WF5 first** (the others point to it as their error workflow), then the rest:

1. In n8n: **Overview → Create → Workflow** (or **Workflows → Add workflow**), then the **…** menu (top right) → **Import from File…**.
2. Choose `WF5-error-handler.json`. Save.
3. Repeat for `WF4-action-runner.json`, `WF2-response-handler.json`, `WF1-hourly-engine.json`, `WF3-daily-jobs.json`, `WF6-discord-checks.json` (one new workflow each).
4. In each workflow, open every node that shows a red credential warning and pick the matching credential from the list
   (the imported files only carry the credential *names*; n8n usually matches them automatically).

## 4. Edit the Config node in every workflow

Every workflow starts with a **Config** Code node. It is the only node you edit. Open it and change the three values:

```js
const supabaseUrl = 'https://YOUR-SANDBOX-PROJECT.supabase.co';   // this environment's Supabase project URL
const pokeUrl     = 'https://YOUR-N8N/webhook/sandbox-sme-poke';   // this environment's WF4 webhook URL (step 6)
const pokeKey     = 'REPLACE_WITH_POKE_SECRET';            // the Poke secret value (step 2.5)
```

Do this in **all six** workflows (WF4 only uses `supabaseUrl`, but keep them identical).

WF3 has two more values: open **Upload to Google Drive** and replace `REPLACE_WITH_SHARED_DRIVE_ID` with the shared
drive ID and `REPLACE_WITH_DRIVE_FOLDER_ID` with the folder ID (each is the last part of the address when you open it
in Drive: `https://drive.google.com/drive/folders/<this part>`).

## 5. Set the error workflow

For **WF1, WF2, WF3, WF4 and WF6**: open the workflow → **…** menu → **Settings** → **Error workflow** → choose
**[Sandbox] WF5 Error handler** (or **[Production] WF5 Error handler**) → Save. (WF5 itself has no error workflow.)

## 6. Publish (activate) the workflows

1. Publish each workflow (n8n 2.x: the **Publish** button at the top; older versions: the **Active** toggle).
   Publish WF5 and WF4 first.
2. Only published workflows run on schedule and answer their **production** webhook URLs
   (`/webhook/...`). The **test** URLs (`/webhook-test/...`) only work while you click "Listen for test event".
3. Production URLs (open the webhook node → **Production URL** to copy them):
   - WF4: `https://<your-n8n>/webhook/sandbox-sme-poke` (Sandbox) or `https://<your-n8n>/webhook/sme-poke` (Production)
   - WF2: `https://<your-n8n>/webhook/sandbox-respond` (Sandbox) or `https://<your-n8n>/webhook/respond` (Production)

## 7. Tell the database and the app where n8n is

1. **Confirm-page URL (WF2)** — must be saved in the database as `app_config.response_base_url`.
   Every instructor button link and the form on every confirm page is built from it.
   - In the app: **Settings → System → Response page URL (n8n WF2)** → `https://<your-n8n>/webhook/respond` → Save, **or**
   - In the Supabase SQL editor:
     ```sql
     update public.app_config set response_base_url = 'https://<your-n8n>/webhook/respond' where id = 1;
     ```
2. **Poke URL + secret (WF4)** — in the app's environment (Vercel → your project → Settings → Environment Variables, and `app/.env.local` for local use):
   - `VITE_N8N_POKE_URL` = `https://<your-n8n>/webhook/sme-poke`
   - `VITE_N8N_POKE_KEY` = the Poke secret value
   - Redeploy the app after changing them.
   - The same URL and secret go in each workflow's **Config** node (step 4).
3. Also set **Settings → System → Admin alert channel ID** in the app so failure alerts and the daily heartbeat have somewhere to go.
4. The app must send the poke as a normal (CORS) `fetch` with the `x-poke-key` header. Browsers silently drop custom
   headers in `no-cors` mode, and n8n then rejects the poke (403). WF4 still delivers within 5 minutes, but not instantly.

Note: the poke key is visible to anyone who can load the app in a browser. That is acceptable because a poke carries no
data and can only make n8n process work that is already in the database. To limit who can call it from a browser,
change **Allowed Origins (CORS)** in WF4's **Poke webhook** node from `*` to the app's address.

## 8. Test it

1. Put a domain in **Test** mode in the app (it needs the test Discord channel and test email set).
2. In the app press **Settings → Send test alert** (team alert) and **Instructors → (a test instructor) → Send test message**.
   Within seconds a message should appear in Discord and/or the inbox. If not, check WF4's **Executions** list.
3. Press **Settings → Run check now** — WF4 runs the engine and sends anything due. In Test mode all instructor messages go to the
   test channel and test email, prefixed `[TEST → would go to <name>]`.
4. Click a button in a test message: the confirm page opens (nothing is recorded yet). Press the button on the page:
   the answer is recorded and follow-up messages arrive within seconds.
5. Type a reply in a test instructor's Discord channel or reply to a test email; after the next hourly run (or run WF1
   manually with **Execute workflow**) it shows up in **Needs Attention**.
6. Run WF3 manually once and check that `sme-backup-YYYY-MM-DD.json` appears in the shared drive folder.
7. To test WF5, temporarily break the Supabase URL in WF1's Config and run WF1 — an admin alert should arrive and a
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
  the rest go on the next poke or within 5 minutes. A row stuck in "Sending" (for example n8n restarted mid-send) is
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
