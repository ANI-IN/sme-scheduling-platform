# n8n workflows

These five workflows connect the database (Supabase) to Discord, Gmail and Google Drive.
They contain **no business rules and no domain, module or instructor names**. Every decision is made by
database functions; n8n only calls them, sends the messages they queue, reports the result back,
serves the pages they render and passes inbound replies to them.

| File | Workflow | Trigger | What it does |
|---|---|---|---|
| `WF1-hourly-engine.json` | WF1 Hourly engine | Every hour | Runs `engine_tick_all` (all checks for all domains), reads Gmail replies and bounces and instructor Discord replies, then pokes WF4. |
| `WF2-response-handler.json` | WF2 Response handler | Webhook `GET` and `POST` `/webhook/respond` | Shows the confirm page (`response_page`), records the answer when the button on the page is pressed (`submit_response_page`), then pokes WF4. |
| `WF3-daily-jobs.json` | WF3 Daily jobs | Every day 09:00 IST | Runs `daily_jobs` (heartbeat), pokes WF4, exports a backup (`export_snapshot`) to Google Drive as `sme-backup-YYYY-MM-DD.json`. |
| `WF4-action-runner.json` | WF4 Action runner | Webhook `POST /webhook/sme-poke` and every 5 minutes | Processes app actions (`next_actions` / `complete_action`) and **delivers all queued messages** by Discord and Gmail (`claim_outbound_messages` / `report_message_result`). This is the only place messages are sent. |
| `WF5-error-handler.json` | WF5 Error handler | n8n error trigger | Records any workflow failure in History (`log_system_error`, which also queues an admin alert) and pokes WF4 so the alert goes out. If the database can't be reached, posts straight to the admin Discord channel. |

"Poke" = an empty `POST` to the WF4 webhook with the header `x-poke-key`. It carries no data; it only tells
WF4 "there is work in the database, process it now". WF4 also runs every 5 minutes, so nothing is lost if a poke fails.

---

## 1. Before you start

You need:

1. The Supabase project URL, e.g. `https://abcdefgh.supabase.co`.
2. Admin access to the company Discord server.
3. A Google Workspace account for the dedicated scheduling mailbox (e.g. `scheduling@…`), and access to Google Cloud Console.
4. A Google Drive folder for the nightly backups.
5. Your n8n address, e.g. `https://n8n.yourcompany.com` (written as `https://<your-n8n>` below).

## 2. Create the credentials

In n8n: **Overview → Credentials → Create credential** (or the **+** menu → Credential). Use exactly these names,
because the workflows look them up by name.

### 2.1 "Supabase secret key" (Header Auth)

1. In Supabase: **Dashboard → Project Settings → API Keys → Secret keys**. Create one (e.g. "n8n") or copy the existing `sb_secret_…` key.
2. In n8n create a credential of type **Header Auth**.
3. Name: `Supabase secret key`.
4. Header **Name**: `apikey`
5. Header **Value**: the `sb_secret_…` key.
6. Do **not** add an `Authorization: Bearer` header. The new Supabase keys only go in the `apikey` header.

Keep this key private: it bypasses all row-level security.

### 2.2 "Discord bot" (Header Auth)

1. Go to <https://discord.com/developers/applications> → **New Application** (e.g. "SME Scheduling").
2. Open **Bot** → **Reset Token** → copy the token.
3. On the same **Bot** page, under **Privileged Gateway Intents**, switch on **MESSAGE CONTENT INTENT** and save.
   Without it the bot sees typed replies as empty text and they can't be read.
4. Invite the bot: **OAuth2 → URL Generator** → scope `bot` → permissions **View Channels**, **Send Messages**,
   **Read Message History** → open the generated URL and add the bot to the company server.
5. Make sure the bot (or its role) can see every instructor channel, the alert channels, the admin channel and the test channel
   (private channels need the bot added explicitly).
6. In n8n create a credential of type **Header Auth**:
   - Name: `Discord bot`
   - Header **Name**: `Authorization`
   - Header **Value**: `Bot ` followed by the token (the word `Bot`, a space, then the token).

### 2.3 "Gmail scheduling" (Gmail OAuth2)

1. In Google Cloud Console create (or pick) a project for the integration.
2. **APIs & Services → Library** → enable **Gmail API**.
3. **APIs & Services → OAuth consent screen** (Google Auth Platform → Branding/Audience): user type **Internal**, fill in the app name and support email.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID** → type **Web application**.
   Under **Authorized redirect URIs** add `https://<your-n8n>/rest/oauth2-credential/callback`
   (the n8n credential window shows this exact URL as "OAuth Redirect URL" — copy it from there).
5. Copy the **Client ID** and **Client secret**.
6. In n8n create a credential of type **Gmail OAuth2 API**, name `Gmail scheduling`, paste the Client ID and secret,
   click **Sign in with Google** and sign in **as the scheduling mailbox** (the address messages should come from and replies go to).

### 2.4 "Google Drive backup" (Google Drive OAuth2)

Same as 2.3, but enable the **Google Drive API** (you can reuse the same Google Cloud project and OAuth client;
the redirect URI is the same). Create an n8n credential of type **Google Drive OAuth2 API** named `Google Drive backup`
and sign in with an account that can write to the backup folder.

### 2.5 "Poke secret" (Header Auth)

1. Make a long random string (e.g. from a password manager, or `openssl rand -hex 24`).
2. In n8n create a credential of type **Header Auth**:
   - Name: `Poke secret`
   - Header **Name**: `x-poke-key`
   - Header **Value**: the random string.
3. Keep the string: it also goes in every Config node (step 4) and in the app (step 7).

## 3. Import the workflows

Import **WF5 first** (the others point to it as their error workflow), then the rest:

1. In n8n: **Overview → Create → Workflow** (or **Workflows → Add workflow**), then the **…** menu (top right) → **Import from File…**.
2. Choose `WF5-error-handler.json`. Save.
3. Repeat for `WF4-action-runner.json`, `WF2-response-handler.json`, `WF1-hourly-engine.json`, `WF3-daily-jobs.json` (one new workflow each).
4. In each workflow, open every node that shows a red credential warning and pick the matching credential from the list
   (the imported files only carry the credential *names*; n8n usually matches them automatically).

## 4. Edit the Config node in every workflow

Every workflow starts with a **Config** Code node. It is the only node you edit. Open it and change the three values:

```js
const supabaseUrl = 'https://YOUR-PROJECT.supabase.co';   // your Supabase project URL
const pokeUrl     = 'https://YOUR-N8N/webhook/sme-poke';   // WF4 production webhook URL (step 6)
const pokeKey     = 'REPLACE_WITH_POKE_SECRET';            // the Poke secret value (step 2.5)
```

Do this in **all five** workflows (WF4 only uses `supabaseUrl`, but keep them identical).

WF3 has one more value: open **Upload to Google Drive** and replace `REPLACE_WITH_DRIVE_FOLDER_ID` with the folder id
(the last part of the folder's URL: `https://drive.google.com/drive/folders/<this part>`).
If the folder is in a shared drive, also pick that drive in the **Drive** field.

## 5. Set the error workflow

For **WF1, WF2, WF3 and WF4**: open the workflow → **…** menu → **Settings** → **Error workflow** → choose
**WF5 Error handler** → Save. (WF5 itself has no error workflow.)

## 6. Publish (activate) the workflows

1. Publish each workflow (n8n 2.x: the **Publish** button at the top; older versions: the **Active** toggle).
   Publish WF5 and WF4 first.
2. Only published workflows run on schedule and answer their **production** webhook URLs
   (`/webhook/...`). The **test** URLs (`/webhook-test/...`) only work while you click "Listen for test event".
3. Production URLs (open the webhook node → **Production URL** to copy them):
   - WF4: `https://<your-n8n>/webhook/sme-poke`
   - WF2: `https://<your-n8n>/webhook/respond`

## 7. Tell the database and the app where n8n is

1. **Confirm-page URL (WF2)** — must be saved in the database as `app_config.response_base_url`.
   Every instructor button link and the form on every confirm page is built from it.
   - In the app: **Settings → System → Response page URL** → `https://<your-n8n>/webhook/respond` → Save, **or**
   - In the Supabase SQL editor:
     ```sql
     update public.app_config set response_base_url = 'https://<your-n8n>/webhook/respond' where id = 1;
     ```
2. **Poke URL + secret (WF4)** — in the app's environment (Cloudflare Pages → your project → Settings → Variables, and `app/.env.local` for local use):
   - `VITE_N8N_POKE_URL` = `https://<your-n8n>/webhook/sme-poke`
   - `VITE_N8N_POKE_KEY` = the Poke secret value
   - Redeploy the app after changing them.
   - The same URL and secret go in each workflow's **Config** node (step 4).
3. Also set the admin Discord channel id in the app (**Settings → System**) so WF5 alerts have somewhere to go.

Note: the poke key is visible to anyone who can load the app in a browser. That is acceptable because a poke carries no
data and can only make n8n process work that is already in the database. To limit who can call it from a browser,
change **Allowed Origins (CORS)** in WF4's **Poke webhook** node from `*` to the app's address.

## 8. Test it

1. Put a domain in **Test** mode in the app (it needs the test Discord channel and test email set).
2. In the app press **Send test message** (Settings) — within seconds a message should appear in the test Discord channel
   and/or test inbox. Check WF4's **Executions** list if not.
3. Press **Run check now** — WF4 runs the engine and sends anything due. In Test mode all instructor messages go to the
   test channel and test email, prefixed `[TEST → would go to <name>]`.
4. Click a button in a test message: the confirm page opens (nothing is recorded yet). Press the button on the page:
   the answer is recorded and follow-up messages arrive within seconds.
5. Type a reply in a test instructor's Discord channel or reply to a test email; after the next hourly run (or run WF1
   manually with **Execute workflow**) it shows up in **Needs Attention**.
6. Run WF3 manually once and check that `sme-backup-YYYY-MM-DD.json` appears in the Drive folder.
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
  (e.g. Discord "Missing Access" / "Unknown Channel", invalid email address), everything else is temporary.
  The database re-queues temporary failures (up to 3 attempts) and raises alerts. If more than 25 are waiting,
  the rest go on the next poke or within 5 minutes. A row stuck in "Sending" (e.g. n8n restarted mid-send) is
  re-queued automatically by the database after 15 minutes.
- **Discord rate limits.** WF4 waits 1 second after each Discord send; WF1 reads channels 2 per second.
- **Discord replies.** Only channels returned by `discord_watchlist()` are read, and only messages written by that
  channel's instructor are recorded. The first time a channel is read, only messages from the last 3 days are recorded,
  so old chat history is not imported.
- **Email replies.** WF1 reads unread inbox mail from the last 3 days and marks it as read once the database has accepted it.
  Do not read the scheduling mailbox's inbox by hand in a way that marks mails read before the hourly run,
  or leave them unread.
- **Branch order.** All workflows use execution order v1: branches run top to bottom, one after another. Some workflows
  rely on that (e.g. WF4 marks actions Done only after delivery). Keep the layout if you move nodes.
- **Optional AI summary.** WF1 has a note showing where an OpenAI node could add a one-line `p_summary` to typed replies.
  AI never decides anything.
- **Timezones.** WF3's workflow timezone is set to Asia/Kolkata, so 09:00 means 09:00 IST regardless of the server timezone.
