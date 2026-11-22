# Configuration

Every value the system needs, in one place: what it is for, whether it is secret, where it goes, the Production value
where it is known, and the step that sets it.

**There is one environment: Production.** It is the old Sandbox under a new name: the same Supabase project
`abcdefghijklmnopqrst`, the same n8n instance and the same Vercel app <https://your-app.vercel.app>. It was
switched on 22 November 2026 with `npm run configure:production -w scripts`, and the database now refuses any reset.
There is no Sandbox any more.

**Internal names keep the word Sandbox on purpose**, because renaming them could break things. They are internal names
only: the n8n credentials `Gmail Sandbox`, `Discord Bot Sandbox`, `Supabase Sandbox`, `Poke Secret Sandbox` and
`Google Drive Backups`, the n8n tag `Sandbox`, the webhook paths such as `/webhook/sandbox-respond` and
`/webhook/sandbox-sme-poke` (links in messages already sent use them), the folder `n8n/sandbox/`, the files
`app/.env.sandbox`, `.env.sandbox.example` and `app/.env.sandbox.example`, and the command `npm run dev:sandbox`. The
column "Separate setup (not used)" holds the values of a second Production setup that was planned but never used.

**Secrets never go into this file, the repository, chat or tickets.** They go only into the place the table names:
Supabase, n8n, Vercel, or a `.env.production` file on your own computer (ignored by git). Keep a copy in your password
manager.

Where a value goes:

- **`.env.production`**: on your computer, read by the scripts (backup, clock, admins, configure, Discord lookups). It
  is the live settings file. It replaced the old `.env.sandbox`, which was deleted on 22 November 2026, and uses the
  same setting names. Start from `.env.sandbox.example` (an internal file name): add the database password in
  `DATABASE_URL` and change `APP_BASE_URL` to `https://your-app.vercel.app`.
- **`app/.env.sandbox`**: on your computer, read by the web app when you run it against the Production database with
  `npm run dev:sandbox` (internal names, kept on purpose). Start from `app/.env.sandbox.example`.
- **Vercel**: the hosting variables of the hosted app (the Production environment of the Vercel project).
- **Supabase**: the dashboard of the project.
- **n8n credential** or **n8n Config node**: in n8n Cloud.
- **App screen**: chosen inside the app, from a list. Nobody types Discord IDs into the app.

## Supabase

| # | Name | What it is for | Secret | Where it goes | Production value | Separate setup (not used) | Step |
|---|---|---|---|---|---|---|---|
| 1 | Project ID (ref) | Links the Supabase command line to the project | No | `npm run db:link -- <ID>` | `abcdefghijklmnopqrst` | | Command 2 |
| 2 | Project URL | The app and n8n talk to the database through it | No | `app/.env.sandbox` and Vercel `VITE_SUPABASE_URL`; n8n Config `supabaseUrl` (filled in) | `https://abcdefghijklmnopqrst.supabase.co` | | Commands 5, 6 |
| 3 | Region, organization | Information only | No | | Northeast Asia (Tokyo, `ap-northeast-1`), "NP Automation" | | Done |
| 4 | Publishable key (`sb_publishable_…`) | The web app's key; the database rules decide what it may do | No (visible in the browser) | `app/.env.sandbox` and Vercel `VITE_SUPABASE_PUBLISHABLE_KEY` | Copy from Project Settings, API Keys | | Command 6 |
| 5 | Secret key (`sb_secret_…`) | n8n reads and writes the database with it | **Yes** | n8n credential `Supabase Sandbox` (Header Auth, name `apikey`) | You add it | | Command 5 |
| 6 | Database password | Applying migrations and running configure | **Yes** | Asked by `npm run db:link` and `db:push`; inside `DATABASE_URL` | You add it | | Commands 2, 4 |
| 7 | `DATABASE_URL` | The connection string the scripts use (Connect, Session pooler, with the password) | **Yes** | `.env.production` | You add it | | Command 4 |
| 8 | Site URL and Redirect URLs | Where Google sign in returns to | No | Supabase, Authentication, URL Configuration | Site URL `https://your-app.vercel.app`; Redirect URLs `https://your-app.vercel.app/**` and `http://localhost:5173/**` (done) | | Done |
| 9 | Google sign in client ID | Sign in with a company Google account | No | Supabase, Authentication, Sign In / Providers, Google | `000000000000-yourclientid.apps.googleusercontent.com` (done, internal app) | | Done |
| 10 | Google sign in client secret | The same | **Yes** | Supabase only | Saved in Supabase (done) | | Done |
| 11 | Email sign in switched off | Only Google accounts may sign in | No | Supabase, Authentication, Sign In / Providers, **Email: "Enable Email provider" off**. Keep "Allow new users to sign up" **on**: turning it off also blocks a colleague's first Google sign in | | | Done |
| 12 | Hook "Before User Created" | Refuses accounts outside the company domain and records the attempt | No | Supabase, Authentication, Hooks: Postgres, schema `public`, function `hook_before_user_created` | | | Command 3 |

## What `npm run configure:production -w scripts` writes into the database

| # | Name | What it is for | Secret | Where it goes | Production value | Separate setup (not used) | Step |
|---|---|---|---|---|---|---|---|
| 13 | `ALLOWED_EMAIL_DOMAIN` | Only accounts of this domain may sign in | No | `.env.production`; also `VITE_ALLOWED_EMAIL_DOMAIN` in `app/.env.sandbox` and Vercel | `yourcompany.com` | `yourcompany.com` | Command 4 |
| 14 | `APP_ENVIRONMENT` | Which rules the database uses: Production (the old Sandbox rules are kept only for a rollback) | No | Set by `configure:production` (`configure:sandbox` only to roll back the switch) | `Production` | `Production` | Command 4 |
| 15 | `SANDBOX_ALLOWED_DISCORD_SERVERS` | The only Discord server the old Sandbox could post to (an internal setting name). **Not used in Production** | No | `.env.production` | `1200000000000000010` | not used | Command 4 |
| 16 | `SANDBOX_ALLOWED_EMAIL_DOMAINS` | The only email domain the old Sandbox could send to (an internal setting name). **Not used in Production** | No | `.env.production` | `yourcompany.com` | not used | Command 4 |
| 17 | `RESPONSE_BASE_URL` | The address of the answer page (n8n WF2) in instructors' buttons | No | `.env.production` | `https://your-instance.app.n8n.cloud/webhook/sandbox-respond` (the path keeps its name) | `https://your-instance.app.n8n.cloud/webhook/respond` | Command 4 |
| 18 | `APP_BASE_URL` | "Open the app" links in messages | No | `.env.production` | `https://your-app.vercel.app` (done) | Its own address | Commands 4, 7 |

**Beta settings.** In Production an admin sets these on **Settings, Admin** (they are not in `.env.production`):
**Who may sign in** = People on the beta list; **Who may receive email** = yourcompany.com only; **Who may
receive Discord messages** = Test instructors and signed in colleagues.

## n8n

| # | Name | What it is for | Secret | Where it goes | Production value | Separate setup (not used) | Step |
|---|---|---|---|---|---|---|---|
| 19 | n8n address | Where the workflows run | No | | `https://your-instance.app.n8n.cloud` | The same | Done |
| 20 | `Gmail Sandbox` | Sends every email and reads replies, with n8n's own Sign in with Google | Kept by n8n | n8n credential (Gmail OAuth2 API) | Done: `scheduling-mailbox@yourcompany.com` | `Gmail Production` | Done |
| 21 | `Discord Bot Sandbox` | Every call to Discord | Kept by n8n | n8n credential (Discord Bot API) | Done | `Discord Bot Production` | Done |
| 22 | `Google Drive Backups` | Uploads the nightly backup and keeps the newest 30 | Kept by n8n | n8n credential (Google Drive OAuth2 API) | Done (B2C account) | `Google Drive Backups Production` | Done |
| 23 | Backup folder ID | Where the backups go | No | n8n WF3, "Upload to Google Drive" and "List backups" (filled in) | `your-drive-folder-id` | | Done |
| 24 | `Supabase Sandbox` | n8n's access to the database | **Yes** (holds the secret key, row 5) | n8n credential (Header Auth: name `apikey`, value the secret key) | You add it | `Supabase Production` | Command 5 |
| 25 | `Poke Secret Sandbox` | Lets the app ask n8n to send at once instead of within 6 minutes | Low (the browser can see it) | n8n credential (Header Auth: name `x-poke-key`); the same value in every Config node `pokeKey` and in `VITE_N8N_POKE_KEY` | A long random string you make | `Poke Secret Production` | Command 5 |
| 26 | Config node `supabaseUrl`, `pokeUrl` | Where each workflow finds the database and WF4 | No | n8n, the Config node of each workflow (filled in) | Row 2, and `https://your-instance.app.n8n.cloud/webhook/sandbox-sme-poke` | | Done |
| 27 | `VITE_N8N_POKE_URL` | The WF4 address the app pokes | No | `app/.env.sandbox` and Vercel | `https://your-instance.app.n8n.cloud/webhook/sandbox-sme-poke` | `…/webhook/sme-poke` | Command 6 |
| 46 | n8n schedule | How often n8n runs without being asked | No | n8n: WF4 every 6 minutes (delivery, Discord checks, typed replies), WF1 every hour (engine), WF3 daily 09:00 IST, WF6 not published | About 8,900 executions a month without the database clock (decision 270). The n8n Cloud Pro plan gives 10,000 a month, shared with the other workflows in the same n8n account | The same | Done |
| 49 | Database clock (Release 3, M1) | The hourly check and the calls to WF4 run from the database (pg_cron jobs `sme-engine-hourly` and `sme-clock`), so n8n runs only when there is work (decision 281) | No | `npm run clock -w scripts -- on <WF4 poke address>` (it sets `app_config.clock_enabled` and `n8n_poke_url`) | **On** since 22 November, 17:36 UTC (poke address `.../webhook/sandbox-sme-poke`; the poke key is in Vault as `n8n_poke_key`) | The same | Done |
| 50 | Poke key in Supabase Vault | The database sends it to WF4 in the `x-poke-key` header | **Yes** | Supabase, SQL editor: `select vault.create_secret('<the poke key>', 'n8n_poke_key');` (you paste the value; it never goes in a file or this chat) | The value of the n8n credential "Poke Secret Sandbox" | The same | You add it |
| 47 | Gmail label | Marks replies WF4 has read, instead of marking them as read | No | Gmail, label "SME Scheduling/Processed"; its ID in `scripts/src/n8n-export.ts` | `Label_1` | Create it in the Production mailbox and put its ID in the export | Done |
| 48 | Reply-To address | Replies to system emails go here, so WF4 never reads the rest of the shared inbox | No | WF4 "Send email" (filled in) | `scheduling-mailbox+scheduling@yourcompany.com` | Its own +scheduling address | Done |
| 28 | Error workflow | WF5 tells the admin channel when a workflow fails | No | n8n, Settings of WF1 to WF4: Error workflow = WF5 (WF6 stays unpublished) | | | Command 5 |

**Direct Gmail access:** nothing in the system needs a Gmail client ID, client secret or refresh token any more. n8n
sends and reads mail with `Gmail Sandbox`. The only thing that used direct access, the automated journey on the hosted
app (`npm run integration:sandbox`), was switched off (decision 252, docs/DEFERRED.md) and is now removed;
docs/READY_FOR_TESTING.md has the same journey as manual steps.

The n8n workflows people see are named `[Production] WF1 Hourly engine` to `[Production] WF6 Discord checks`
(n8n/README.md explains the two folders of exported files).

## Discord

| # | Name | What it is for | Secret | Where it goes | Production value | Separate setup (not used) | Step |
|---|---|---|---|---|---|---|---|
| 29 | Application ID | Builds the bot invite link on Settings, Connections | No | `app/.env.sandbox` and Vercel `VITE_DISCORD_CLIENT_ID` | `1200000000000000017` | | Command 6 |
| 30 | Bot token | The bot's password | **Yes** | Only in the n8n credential (row 21) | Done | | Done |
| 31 | Server Members Intent, Message Content Intent | Finding people by username, reading typed replies | No | Discord Developer Portal, Bot | On (done) | | Done |
| 32 | Bot permissions | View Channels, Send Messages, Embed Links, Read Message History | No | The invite link; the bot's role on the "Test instructors" category and on private channels | | | Done |
| 33 | Server ID | The test Discord server the hosted app uses | No | `.env.production` (row 15, not used in Production); in the app: Settings, Connections, Discord servers, choose it for each domain | `1200000000000000010` | | Commands 4, 8 |
| 34 | Alert channel | The team is tagged here about a domain | No | App: Setup, Domains, the domain, Alert channel (chosen from the list) | `#alerts`, `1200000000000000012` | | Command 8 |
| 35 | Admin alert channel | Problems with the app and the daily system summary | No | App: Settings, Connections, Admin alert channel | `#admin-alerts`, `1200000000000000013` | | Command 8 |
| 36 | Test instructor channels | Each test instructor's own channel | No | App: Setup, Instructors, each instructor, channel for the domain | `#test-instructor-a` `1200000000000000014`, `#test-instructor-b` `1200000000000000015`, `#test-instructor-c` `1200000000000000016` (category "Test instructors") | | Command 8 |
| 37 | Testing channel | Where every message of a domain goes while the domain's status is **Testing** | No | App: Setup, Domains (Testing status) and Settings, Testing | **Create a channel named `testing`** in the test Discord server (row 33). No ID is needed: choose it from the list | | Command 8 |
| 38 | Your Discord user ID | Tagging you and sending you direct messages | No | Nowhere: type your Discord username on Setup, Team, and the app finds the ID | `1200000000000000008` | | Command 8 |

## Email

| # | Name | What it is for | Secret | Where it goes | Production value | Separate setup (not used) | Step |
|---|---|---|---|---|---|---|---|
| 39 | Sender mailbox | Where emails come from and replies go | No | The `Gmail Sandbox` credential (done); app: Settings, Connections, Advanced: links, Sender email | `scheduling-mailbox@yourcompany.com` | | Command 8 |
| 40 | Test instructor emails | Test instructors; they all arrive in the B2C inbox | No | App: Setup, Instructors, tick "Test instructor" | `scheduling-mailbox+instructor-a@yourcompany.com`, `+instructor-b`, `+instructor-c` | | Command 8 |
| 41 | Testing email | Where emails go while a domain is in Testing | No | App: Setup, Domains (Testing status) | Suggested: `scheduling-mailbox+testing@yourcompany.com` | | Command 8 |

## Hosting

| # | Name | What it is for | Secret | Where it goes | Production value | Separate setup (not used) | Step |
|---|---|---|---|---|---|---|---|
| 42 | Hosting project | Serves the web app | No | Vercel, team "your-team's projects" (Hobby), project `sme-scheduling`, deployed with the Vercel command line from this folder (no GitHub link); `.vercelignore` keeps every `.env` file out | `https://your-app.vercel.app` (done) | | Command 7 |
| 43 | Hosting variables | The same `VITE_` values as `app/.env.sandbox` | No (the browser sees them) | Vercel, Settings, Environment Variables, Production (the one hosted environment) | Rows 2, 4, 13, 25, 27, 29 and 44 (done) | | Command 7 |
| 44 | `VITE_ENABLE_DEV_LOGIN` | Email link sign in for the local stack only | No | Never set on a hosted app | `false` | `false` | |
| 45 | OpenAI key (optional) | A one line summary of typed replies | **Yes** | n8n credential `OpenAI Sandbox` | Not needed | | Optional |

**Vercel plan.** The app is hosted on Vercel's free Hobby plan, which is for non commercial use. Cloudflare Pages is
the free alternative the app already supports: both `vercel.json` and Cloudflare Pages work (docs/SETUP_GUIDE.md,
part 7). Hosting is not changed for now.

## Commands for me to run

Run these in a terminal in the repository folder, in order. On Windows, first copy `.npmrc.windows-example` to
`.npmrc` (the folder name has `&`).

**1. Install**

```bash
npm ci
```

**2. Link the Supabase command line to the Production project and apply the migrations.** The last two ask for the
database password.

```bash
npm run db:login
```

```bash
npm run db:link -- abcdefghijklmnopqrst
```

```bash
npm run db:push -- --remote
```

With the current Supabase command line, `db:push` without `--remote` goes to the local database.

**3. In the Supabase dashboard** (no command): switch off "Enable Email provider" in the Email provider, and keep
"Allow new users to sign up" on (row 11). Add the "Before User Created" hook (row 12).

**4. Tell the database it is Production (done on 22 November 2026).** In `.env.production` (if you have none, copy
`.env.sandbox.example` to `.env.production` and change `APP_BASE_URL` to `https://your-app.vercel.app`), put the
Session pooler connection string with your password in `DATABASE_URL`, then:

```bash
npm run configure:production -w scripts
```

It prints the environment and the allowed sign in domain. Run it again whenever a value in `.env.production` changes.
`npm run configure:sandbox -w scripts` is kept only to roll back the switch; it also reads `.env.production`. The
other script commands read `.env.production` too: `npm run backup -w scripts -- --label <label>`,
`npm run clock -w scripts -- status|on|off`, `npm run admins -w scripts -- list|add|remove <email>` and
`npm run discord:production -w scripts`.

**5. n8n.** Make the workflow files, then import them in n8n.

```bash
npm run n8n-export -w scripts
```

Then, in n8n Cloud (n8n/README.md has every click):

1. Create the two missing credentials: `Supabase Sandbox` and `Poke Secret Sandbox` (rows 24, 25).
2. Import the files from `n8n/sandbox/` (the Production workflows, named `[Production] WFn ...`), WF5 first (WF6
   may be imported but stays unpublished).
3. In the Config node of WF2 to WF5, set `pokeKey` to the Poke Secret Sandbox value.
4. Set WF5 as the Error workflow of WF1 to WF4, then publish WF5 and WF4 first, then WF2, WF1 and WF3. Leave WF6 unpublished: WF4 does its Discord checks (decision 270).

**6. Run the app on your computer against the Production database.** Copy `app/.env.sandbox.example` to
`app/.env.sandbox` (internal file names), add the publishable key (row 4) and the poke key (row 25), then:

```bash
npm run dev:sandbox
```

Open <http://localhost:5173> and sign in with a Google account that is on the beta list (admins manage the list on
**Settings, Admin**).

**7. Hosting (done).** Deploy from this folder with the Vercel command line:

```bash
npx vercel@65.14.0 deploy --prod
```

The project, its variables, the Supabase Redirect URL, the Google JavaScript origin and `APP_BASE_URL` are set (rows 8,
18, 42, 43).

**8. Set up your domain in the app** (no command). The hosted app starts empty, and each tester sets up their own
domain; there is no demo data to load and the database refuses any reset. Follow the Get started list on Home. Add the domain, choose its Discord server on
Settings, Connections (press **Refresh servers** first), its alert channel and the admin alert channel, add yourself
and the team with Discord usernames, add the three test instructors with their channels, add modules and a cohort,
and plan classes.

## Local development and tests (no accounts needed)

| Name | What it is for | Where it goes | Value |
|---|---|---|---|
| Local stack | Your own copy of the database (Docker) | `npm run db:start` | Ports 5542x |
| Test stack | A separate copy the automated tests build, fill and remove (decision 250). `npm run demo -w scripts -- load` fills only this stack, never the hosted database | `npm run e2e`, `npm run help:screenshots`, `npm run integration:rehearse -w scripts` | Ports 5552x, app on 5174 |
| `app/.env.local` | The app against the local stack | Copy `app/.env.example` | Local address and key printed by `db:start` |
