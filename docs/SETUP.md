# Setup guide

Step-by-step instructions for connecting the real services. You do not need to write code. Follow the steps in order;
each one says exactly where every key or ID goes. Keep a private note of the values as you collect them
(never paste secrets into chat, tickets or the repository).

**What you will set up:** Supabase (database and sign-in) → Google Cloud (Google sign-in and Gmail) → Discord bot →
n8n (automation) → Cloudflare Pages (the web app) → first checks.

| Value | Where you get it | Where it goes |
|---|---|---|
| Supabase project URL | Supabase → Project Settings → API | Cloudflare env `VITE_SUPABASE_URL`; n8n Config node `supabaseUrl` |
| Supabase publishable key (`sb_publishable_…`) | Supabase → Project Settings → API Keys | Cloudflare env `VITE_SUPABASE_PUBLISHABLE_KEY` |
| Supabase secret key (`sb_secret_…`) | Supabase → Project Settings → API Keys → Secret keys | n8n credential "Supabase secret key" only |
| Company email domain (e.g. `yourcompany.com`) | — | SQL in step 1.4; Cloudflare env `VITE_COMPANY_EMAIL_DOMAIN` |
| Google OAuth client ID + secret (sign-in) | Google Cloud → Credentials | Supabase → Authentication → Providers → Google |
| Google OAuth client (Gmail/Drive for n8n) | Google Cloud → Credentials | n8n credentials "Gmail scheduling", "Google Drive backup" |
| Discord bot token | Discord Developer Portal → Bot | n8n credential "Discord bot" (`Bot <token>`) |
| Discord server ID | Discord (Developer Mode) → right-click server → Copy Server ID | App → Settings → System → Company Discord server ID |
| Discord channel IDs (alert, admin, test) | Right-click channel → Copy Channel ID | App → Modules (alert), Settings → System (admin), Settings → Test mode (test) |
| WF2 URL `https://<n8n>/webhook/respond` | n8n → WF2 → webhook node → Production URL | App → Settings → System → Response page URL |
| WF4 URL `https://<n8n>/webhook/sme-poke` + poke secret | n8n → WF4 | Cloudflare env `VITE_N8N_POKE_URL`, `VITE_N8N_POKE_KEY`; n8n Config nodes |
| App URL (e.g. `https://ik-scheduling.pages.dev`) | Cloudflare Pages | Supabase → Authentication → URL Configuration; App → Settings → System → App URL |

---

## 1. Supabase (database, rules and sign-in)

### 1.1 Create the project
1. Go to <https://supabase.com>, sign in and click **New project**.
2. Name it (e.g. `ik-scheduling`), choose a strong database password (save it privately) and a region near your team.
3. Wait until the project is ready.

### 1.2 Create the tables and functions
Choose **one** of these:

**A. With the command line (recommended, needs Node.js 20+):** in a terminal in the repository folder:
```bash
npm install
```
```bash
npx supabase login
```
```bash
npx supabase link --project-ref <your-project-ref>
```
```bash
npx supabase db push
```
(`<your-project-ref>` is the part of the project URL before `.supabase.co`.)

**B. Without the command line:** open Supabase → **SQL Editor**. Open each file in `supabase/migrations/` in name order
(`…000001_foundation.sql` first, `…000008_html_media_type.sql` last), paste its whole content, press **Run**, and check
it says *Success* before the next file.

### 1.3 Load the Backend starting data
In **SQL Editor**, paste the content of `supabase/seed.sql` and press **Run**. This creates the Backend domain in
**Test** status, its 5 modules with the class pattern and the rankings from the PRD (Appendix A), 3 test instructors and
placeholder team members. Every placeholder is marked `PLACEHOLDER` — you replace them in the app later (step 6).

### 1.4 Set your company email domain
Still in the SQL Editor, run (with your real domain, lowercase, without `@`):
```sql
update public.app_config set company_email_domain = 'yourcompany.com' where id = 1;
```
Only Google accounts ending in `@yourcompany.com` can sign in and read data. (This can only be changed here, on purpose.)

### 1.5 Block other accounts at sign-up
Supabase → **Authentication → Hooks** → **Add hook** → **Before User Created** → type **Postgres function** →
schema `public`, function `hook_before_user_created` → **Create**. Accounts from other domains are now refused and logged
in History (the database also refuses their data access even without this hook).

### 1.6 Sign-in URLs
Supabase → **Authentication → URL Configuration**:
- **Site URL:** your app URL from step 5 (e.g. `https://ik-scheduling.pages.dev`). You can come back after step 5.
- **Redirect URLs:** add the same app URL.

## 2. Google Cloud (Google sign-in, Gmail, Drive)

Use your Google Workspace admin account if you can (an *Internal* app never expires its tokens).

### 2.1 Project and consent screen
1. <https://console.cloud.google.com> → create a project (e.g. `ik-scheduling`).
2. **APIs & Services → OAuth consent screen** → User type **Internal** → app name `SME Scheduling`, support email → Save.

### 2.2 Google sign-in for the app
1. **APIs & Services → Credentials → Create credentials → OAuth client ID** → **Web application**.
2. **Authorized redirect URIs:** copy it from Supabase → **Authentication → Providers → Google** (it looks like
   `https://<project-ref>.supabase.co/auth/v1/callback`).
3. Create, then copy the **Client ID** and **Client secret**.
4. Supabase → **Authentication → Providers → Google** → enable, paste Client ID and Client secret → Save.

### 2.3 Gmail and Drive for n8n
1. **APIs & Services → Library**: enable **Gmail API** and **Google Drive API**.
2. Create another **OAuth client ID** (Web application) with redirect URI `https://<your-n8n>/rest/oauth2-credential/callback`.
3. Keep its Client ID and secret for the n8n credentials in step 4 (see `n8n/README.md` §2.3–2.4).
4. Sign in to n8n's Gmail credential with the **dedicated scheduling mailbox** (e.g. `scheduling@yourcompany.com`).

## 3. Discord bot

1. <https://discord.com/developers/applications> → **New Application** → name `SME Scheduling`.
2. **Bot** tab → **Reset Token** → copy the token (shown once). Under **Privileged Gateway Intents** switch on
   **MESSAGE CONTENT INTENT** (needed to read typed replies) → Save.
3. **OAuth2** tab: copy the **Application ID**. Open this link (replace the ID) and add the bot to the company server:
   `https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=bot&permissions=68608`
   (permissions = View Channel + Send Messages + Read Message History).
4. Make sure the bot's role can see and post in: every instructor channel, the domain alert channel, the admin channel
   and the test channel (channel → Edit → Permissions → add the bot role).
5. In Discord **User Settings → Advanced → Developer Mode: on**. Now right-click → **Copy ID** works for the server,
   channels and people:
   - Server ID → app **Settings → System → Company Discord server ID**
   - Admin channel ID → **Settings → System → Admin alert channel ID**
   - Domain alert channel ID → **Modules → Alert Discord channel ID**
   - Test channel ID → **Settings → Test mode → Test Discord channel ID**

## 4. n8n (automation)

Follow `n8n/README.md` — it covers creating the 5 credentials, importing WF1–WF5, editing the **Config** node in each
workflow, setting the error workflow and publishing. You will need the Supabase URL and secret key (step 1), the Google
clients (step 2) and the Discord token (step 3). At the end, copy:
- the WF2 production URL → app **Settings → System → Response page URL**, and
- the WF4 URL and poke secret → Cloudflare env in step 5.

## 5. Cloudflare Pages (the web app)

1. Put this repository on GitHub (private).
2. <https://dash.cloudflare.com> → **Workers & Pages → Create → Pages → Connect to Git** → pick the repository.
3. Build settings:
   - **Framework preset:** None
   - **Build command:** `npm ci && npm run build -w app`
   - **Build output directory:** `app/dist`
   - **Root directory:** (leave empty)
4. **Environment variables** (Production): `NODE_VERSION` = `22`, and
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_COMPANY_EMAIL_DOMAIN`, `VITE_N8N_POKE_URL`,
   `VITE_N8N_POKE_KEY` (see `app/.env.example`). Do **not** set `VITE_ENABLE_DEV_LOGIN`.
5. **Save and Deploy.** The app URL is shown when it finishes (e.g. `https://ik-scheduling.pages.dev`).
   Page refreshes on deep links work thanks to `app/public/_redirects`.
6. Go back to Supabase step 1.6 and set the Site URL / Redirect URL to this address, and put it in the app under
   **Settings → System → App URL**.

(Cloudflare now also offers "Workers with static assets" for new projects; Pages is used here because it is simpler and
free. Either works for this app.)

## 6. First checks (about 30 minutes)

1. Open the app and **Sign in with Google** using a company account. An outside account must be refused.
2. **Settings → Team:** replace the three team members marked "Needs real details" (Module owner, Operations, Lead) with real people (name, email,
   Discord user ID) and add the rest of the team. Press **Send test alert** for yourself.
3. **Settings → System:** fill in the Discord server ID, admin channel ID, response page URL, app URL and scheduling email.
4. **Modules:** set the domain's alert channel, leads and ops contacts; check each module's owners, pattern, resources
   (replace the placeholder links) and ranking (API Design's first choice is still to be decided).
5. **Instructors:** replace each placeholder email, add Discord user IDs and channel links, then **Send test message**
   until everyone shows **✓ Verified**. Point the 3 test instructors at team members' own Discord/email.
6. **Settings → Test mode:** set the test channel and test email; keep **Backend** in Test.
7. **Schedule → Plan classes:** plan at least 8 weeks.
8. **Settings → Test mode:** use **Jump to** / **Run check now** and watch the test channel. Walk through the scenarios
   in the PRD (§20.3) with the test instructors.
9. When ops signs off after the shadow run, press **Turn test mode off (go Live)**.

## Local development (optional)

Needs Docker Desktop and Node.js 20+.
```bash
npm install
```
```bash
npm run db:start
```
Copy `app/.env.example` to `app/.env.local` and use the local URL/key printed by `db:start` (local ports are 5542x),
`VITE_COMPANY_EMAIL_DOMAIN=example.com` and `VITE_ENABLE_DEV_LOGIN=true`. Then:
```bash
npm run dev -w app
```
Sign in with any `@example.com` address; the sign-in link arrives in the local mail catcher at http://127.0.0.1:55424.

Useful commands: `npm run db:test` (database tests), `npm test` (app tests), `npm run mock -- --race` (full engine
timeline without credentials), `npm run check` (format, lint, types, tests, build).

**Windows and folder names with `&`:** npm's default Windows shell breaks on paths containing `&`. If your folder name
has one, copy `.npmrc.windows-example` to `.npmrc` (it makes npm scripts run in Git Bash). `.npmrc` is not committed.
