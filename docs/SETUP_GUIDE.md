# Setup guide

This guide connects the app to the real services, for two separate environments:

- **Sandbox**: a full copy of the system for practice and testing. It has its own database, its own Discord bot and
  server, its own mailbox and its own web address. It can only send messages to the test Discord server and to the
  email domains you allow. It can never message a real instructor.
- **Production**: the real system the Operations team uses every day. It never messages an instructor marked as a
  test instructor.

You do not need to write code. Follow the parts in order and tick the checklist at the end as you go.
Set up **Sandbox first**, try it, then repeat the same steps for Production.

**Keep secrets safe.** Secret keys, tokens and passwords go only into the place this guide names (Supabase, n8n,
Vercel or a local `.env.sandbox` or `.env.production` file on your computer). Never paste them into chat, tickets,
documents, the checklist or the repository. Keep a copy in your company password manager.

**What you need before you start**

- A Google Workspace admin account for your company domain (or someone who has one).
- Admin rights on the company Discord server, and permission to create a second Discord server for testing.
- An n8n instance (n8n Cloud or your own server) where you can create credentials and import workflows.
- A Vercel account on a paid plan, or a free Cloudflare account (see part 7).
- Node.js 22 and Git installed on your computer, and a copy of this repository.
- About half a day for Sandbox, and about two hours for Production.

---

## Part 1. Supabase (the database)

Do this once for Sandbox and once for Production. Each environment has its **own** Supabase project.

### 1.1 Create the project

1. Go to <https://supabase.com/dashboard> and click **New project**.
2. Name it `sme-scheduling-sandbox` (or `sme-scheduling-production`).
3. Choose a strong database password and save it in the password manager. Pick the region closest to your team.
4. Wait until the project is ready (about two minutes).

### 1.2 Collect the project values

1. **Project URL** and **Project ref**: **Project Settings → Data API**. The URL looks like
   `https://abcdefghijklmnop.supabase.co`; the ref is the part before `.supabase.co`.
2. **Publishable key** (`sb_publishable_…`): **Project Settings → API Keys**. It is safe to use in the web app.
3. **Secret key** (`sb_secret_…`): **Project Settings → API Keys → Secret keys → New secret key**, name it `n8n`.
   This key can read and change everything. It goes only into n8n.
4. **Database connection string**: click **Connect** at the top of the dashboard → **Session pooler** → copy the URI
   and put your database password in place of `[YOUR-PASSWORD]`. It is used only on your computer in step 1.4.

### 1.3 Create the tables, rules and functions

In a terminal in the repository folder:

```bash
npm ci
```

```bash
npx supabase login
```

```bash
npx supabase link --project-ref <the project ref>
```

```bash
npx supabase db push
```

`db push` applies every file in `supabase/migrations/` in order. Run it again after each app update.

**Production only:** load the Backend starting data (modules, class pattern and rankings from the PRD, with
placeholder people you replace later). Open **SQL Editor**, paste the whole of `supabase/seed.sql`, press **Run**.
Sandbox does not need this file; it gets its own practice data in part 8.

### 1.4 Tell the database which environment it is

1. Copy `.env.example` (in the repository root) to `.env.sandbox` (or `.env.production`). These two files are ignored
   by Git, so they never leave your computer.
2. Fill in:

   | Name | Sandbox | Production |
   |---|---|---|
   | `DATABASE_URL` | Sandbox connection string from 1.2 | Production connection string from 1.2 |
   | `APP_ENVIRONMENT` | `Sandbox` | `Production` |
   | `ALLOWED_EMAIL_DOMAIN` | Your company domain, for example `yourcompany.com` | The same |
   | `SANDBOX_ALLOWED_DISCORD_SERVERS` | The Sandbox Discord server ID (part 4) | Leave empty |
   | `SANDBOX_ALLOWED_EMAIL_DOMAINS` | Your company domain, so test emails only reach your own team | Leave empty |

3. Run:

   ```bash
   npm run configure:sandbox -w scripts
   ```

   or, for Production:

   ```bash
   npm run configure:production -w scripts
   ```

   It prints the environment and the allowed sign in domain. Run it again whenever you change one of these values
   (for example after you know the Discord server ID).

### 1.5 Only company Google accounts may sign in

1. **Authentication → Sign In / Providers**: switch **off** "Allow new users to sign up" for **Email**, and keep
   **Google** on (you fill it in at 2.2).
2. **Authentication → Hooks → Add hook → Before User Created** → type **Postgres** → schema `public`, function
   `hook_before_user_created` → **Create hook**.

   This hook refuses every account outside your company domain and records the attempt in Activity history.
   In Production it also refuses anything that is not a company Google Workspace account. The database checks the same
   rule on every request, so data stays private even if the hook is switched off by mistake.

### 1.6 Web addresses

**Authentication → URL Configuration**:

- **Site URL**: the app address for this environment (from part 7). You can come back to this after part 7.
- **Redirect URLs**: add the same address followed by `/**`, for example `https://scheduling.yourcompany.com/**`.

---

## Part 2. Google Cloud

One Google Cloud project holds everything, with a separate sign in client for each environment.

### 2.1 Project and consent screen (once)

1. Go to <https://console.cloud.google.com> signed in with your Google Workspace account. Create a project named
   `SME Scheduling`.
2. **Google Auth Platform → Branding**: app name `SME Scheduling`, your support email, save.
3. **Audience**: user type **Internal**. Internal means only accounts in your Workspace can use it, and Google does
   not need to review the app.

### 2.2 Google sign in for the app (once per environment)

1. **Google Auth Platform → Clients → Create client** → type **Web application**, name `App sign in (Sandbox)` or
   `App sign in (Production)`.
2. **Authorized redirect URIs**: copy the **Callback URL** from Supabase **Authentication → Sign In / Providers →
   Google**. It looks like `https://<project ref>.supabase.co/auth/v1/callback`.
3. Create, then copy the **Client ID** and **Client secret**.
4. In Supabase **Authentication → Sign In / Providers → Google**: switch it on, paste the Client ID and Client secret,
   save.

### 2.3 Gmail and Drive access for n8n (once per environment)

1. **APIs & Services → Library**: enable **Gmail API** and **Google Drive API** (once).
2. **Google Auth Platform → Clients → Create client** → **Web application**, name `n8n (Sandbox)` or `n8n (Production)`.
3. **Authorized redirect URIs**: `https://<your n8n address>/rest/oauth2-credential/callback` (n8n shows this exact
   address as "OAuth Redirect URL" when you create the Gmail credential in part 5).
4. Copy the Client ID and Client secret. They go into the n8n credential `Gmail scheduling (<env>)`.

### 2.4 Service account for the nightly backup (once per environment)

A service account is a Google account for a program instead of a person. The backup keeps working when people leave.

1. **IAM & Admin → Service Accounts → Create service account**, name `sme-backup-sandbox` or `sme-backup-production`.
   It needs no roles. Create.
2. Open it → **Keys → Add key → Create new key → JSON**. A file downloads. Treat it like a password.
3. In Google Drive create a **shared drive** named `Scheduling backups` (once), with a folder `Sandbox` and a folder
   `Production`. Add each service account's email (it ends in `iam.gserviceaccount.com`) as **Content manager**.
4. You paste the key into n8n in part 5, then delete the downloaded file.

---

## Part 3. Gmail mailboxes

Each environment sends from its own mailbox, so a test can never look like a real message.

1. In the Google Admin console create (or choose) two mailboxes, for example `scheduling@yourcompany.com` for
   Production and `scheduling-sandbox@yourcompany.com` for Sandbox. A Google Group cannot be used; it must be a
   real mailbox, because n8n reads the replies.
2. Sign in to each once in a browser to finish its setup.
3. The Sandbox test instructors use **plus addresses** of one mailbox, for example
   `you+a@yourcompany.com`, `you+b@yourcompany.com`. Gmail delivers them all to `you@yourcompany.com`, so one person
   can play six instructors.

---

## Part 4. Discord

The app uses Discord servers you already have. It never creates servers or channels.

### 4.1 Servers

- **Production**: each domain uses its existing Discord server (several domains may share one), where the
  instructors and the team already are. Instructors have their own channels, usually in a category named `1-1`.
- **Sandbox**: a separate test server. Create it: in Discord click **+** (Add a Server), **Create My Own**, name it
  `SME Scheduling Sandbox`. Invite the people who will test. Create a category `1-1` with a few test channels, plus
  `#alerts`, `#admin` and `#testing`.

### 4.2 One bot per environment

1. Go to <https://discord.com/developers/applications>, **New Application**, name `SME Scheduling Sandbox` (or
   `SME Scheduling`).
2. **Bot**, **Reset Token**, copy the token (it is shown once). It goes only into the n8n credential
   `Discord bot (<env>)`, and on your own computer into the environment variable `DISCORD_BOT_TOKEN` when you run
   `npm run discord -w scripts`. Never put it in a file that is committed.
3. On the same page, under **Privileged Gateway Intents**, switch on **Server Members Intent** (the app finds people
   by their Discord username) and **Message Content Intent** (the app reads typed replies). Save.
4. **General Information**: copy the **Application ID**. Set it as `VITE_DISCORD_CLIENT_ID` for the web app (it is
   not a secret). The app then shows the invite link on **Settings, Connections, Discord servers**.
5. Open the invite link and add the bot to each server (the Sandbox bot to the Sandbox server only). The link asks
   for exactly four permissions: View Channels, Send Messages, Embed Links and Read Message History.
6. In each server, open the `1-1` category, **Edit Category**, **Permissions**, add the bot's role and allow the same
   four permissions. Do the same for the alert, admin and testing channels if they are private.

### 4.3 In the app

1. **Settings, Connections, Discord servers**: press **Refresh servers**. The servers the bot is in appear within a
   minute.
2. Choose the server of each domain. The app checks it and lists the channels the bot can see. Wait for **Ready**;
   if it says **Needs a fix**, it says exactly what to change.
3. **Setup, Instructors**: for each instructor, type their **Discord username** (for example `maya.k`, without @)
   and choose their channel for each domain from the list. The app finds their Discord account by itself and shows
   **Discord found**, or what is wrong. Nobody types Discord user IDs.
4. **Setup, Team**: a Discord username is optional. People without one get email instead.
5. **Setup, Domains** and **Settings, Testing**: choose the alert channel and the testing channel from the list.

| Value | Where it comes from | Where it goes |
|---|---|---|
| Bot token (secret) | Developer Portal, Bot | n8n credential `Discord bot (<env>)`; locally `DISCORD_BOT_TOKEN` |
| Application ID | Developer Portal, General Information | `VITE_DISCORD_CLIENT_ID` (web app) |
| Sandbox server ID | Right click the server, Copy Server ID (turn on Developer Mode first) | `SANDBOX_ALLOWED_DISCORD_SERVERS` (1.4) |

---

## Part 5. n8n (the automation)

n8n only moves messages in and out. Every decision is made by the database.

1. In the repository run:

   ```bash
   npm run n8n-export -w scripts
   ```

   This writes `n8n/sandbox/` and `n8n/production/`. Each set has its own workflow names (`[Sandbox] …`,
   `[Production] …`), tag, credential names and webhook addresses, so both can live in the same n8n.
2. Follow `n8n/README.md` from section 2. In short, for each environment:
   1. Create five credentials with exactly these names: `Supabase secret key (<env>)`, `Discord bot (<env>)`,
      `Gmail scheduling (<env>)`, `Google service account (<env>)`, `Poke secret (<env>)`.
      For the poke secret, make a long random string (for example from the password manager's generator).
   2. Import the five files from `n8n/sandbox/` (or `n8n/production/`), WF5 first.
   3. In every workflow open the **Config** node and set `supabaseUrl`, `pokeUrl` and `pokeKey`.
   4. In WF3 **Upload to Google Drive**, set the shared drive ID and the folder ID.
   5. Set WF5 as the **Error workflow** of WF1 to WF4. Publish WF5 and WF4 first, then the rest.
3. Copy the two webhook addresses:

   | Webhook | Sandbox | Production | Where it goes |
   |---|---|---|---|
   | WF2 confirm pages | `https://<your n8n>/webhook/sandbox-respond` | `https://<your n8n>/webhook/respond` | App: **Settings → Connections → Advanced → Response page link** |
   | WF4 poke | `https://<your n8n>/webhook/sandbox-sme-poke` | `https://<your n8n>/webhook/sme-poke` | Hosting variable `VITE_N8N_POKE_URL` (part 7) |

---

## Part 6. OpenAI (optional)

The system works fully without AI. If you want a one line summary of typed replies for the Operations team:

1. Go to <https://platform.openai.com> → **API keys** → **Create new secret key**, name `SME Scheduling (<env>)`.
2. **Settings → Limits**: set a low monthly budget (for example 5 US dollars). Replies are short, so the real cost is
   under one dollar a month.
3. In n8n create a credential of type **OpenAI**, name `OpenAI (<env>)`, paste the key.
4. In WF1, add an **OpenAI** node where the note "Optional AI summary" says, using the smallest suitable model. It only
   fills the summary; it never decides anything.

You can skip OpenAI for Sandbox.

---

## Part 7. The web app (Vercel or Cloudflare Pages)

The app is a set of static files. Both options below work; choose one.

**Vercel** needs a paid plan (Pro) for company use: the free Hobby plan does not allow commercial use.
**Cloudflare Pages** is free for company use.

### 7.1 Put the code on GitHub

Push this repository to a **private** GitHub repository. Create a branch named `sandbox`: the Sandbox site is built from
it and the Production site from `main`.

### 7.2 Option A: Vercel

1. <https://vercel.com/new> → import the repository. Vercel reads `vercel.json`, so leave the build settings as they are
   (install `npm ci`, build `npm run build -w app`, output `app/dist`, and every address opens the app).
2. **Settings → Environment Variables**. Add each variable twice: once for **Production** with the Production values,
   once for **Preview** with the Sandbox values.

   | Name | Sandbox (Preview) | Production |
   |---|---|---|
   | `VITE_SUPABASE_URL` | Sandbox project URL | Production project URL |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | Sandbox publishable key | Production publishable key |
   | `VITE_ALLOWED_EMAIL_DOMAIN` | Your company domain | Your company domain |
   | `VITE_N8N_POKE_URL` | Sandbox WF4 address | Production WF4 address |
   | `VITE_N8N_POKE_KEY` | Sandbox poke secret | Production poke secret |

   Never set `VITE_ENABLE_DEV_LOGIN` here; it is for your own computer only.
3. **Settings → Git → Production Branch**: `main`.
4. **Settings → Domains**: add your Production address (for example `scheduling.yourcompany.com`) for `main`, and a
   Sandbox address (for example `scheduling-sandbox.yourcompany.com`) for the branch `sandbox`.
5. Deploy. Changes to `main` update Production; changes to `sandbox` update Sandbox.

### 7.3 Option B: Cloudflare Pages

1. <https://dash.cloudflare.com> → **Workers & Pages → Create → Pages → Connect to Git** → choose the repository.
2. Build settings: framework **None**, build command `npm ci && npm run build -w app`, output directory `app/dist`.
3. **Settings → Variables and Secrets**: add `NODE_VERSION` = `22` and the variables from the table in 7.2, once for
   **Production** and once for **Preview**.
4. Production branch `main`. The `sandbox` branch is published at `https://sandbox.<project>.pages.dev`; you can add a
   custom domain for it.
   (`app/public/_redirects` makes every address open the app.)

### 7.4 Finish the links

1. Back in Supabase (1.6), set the **Site URL** and **Redirect URLs** to this environment's app address.
2. Sign in to the app. Go to **Settings → Connections → Advanced: links and IDs** and fill in **App link**,
   **Response page link** and **Sender email**, then choose the **Admin alert channel**. Then set up the Discord
   servers as in 4.3.

---

## Part 8. First checks

### 8.1 Sandbox

1. Open the Sandbox address. A **Sandbox** label shows at the top of every page.
2. **Sign in with Google** with your company account. Try an account from outside the company: it must be refused.
3. **Settings → Testing → Reset Sandbox data**, type `RESET`. This loads the practice data: Backend and Fullstack, each
   with a weekend and a weekday cohort, eight weeks of classes and six test instructors.
4. **Setup → Instructors**: point the test instructors at your own plus addresses and your own Discord username, then press
   **Send contact check** for one of them. It must arrive within a minute.
5. **Settings → Testing → Run a practice class**. Every stage should pass.
6. **Settings → Connections**: Discord, Email and Automation service should all show **Working**.
7. Walk through the scenarios in the PRD (section 20.3) with the test instructors and the practice clock.

### 8.2 Production

1. Sign in. No label shows at the top. **Settings → Connections** shows **Working** for everything.
2. **Setup → Team**: replace every person marked "needs real details" with real people, and add the rest of the team.
3. **Setup → Instructors**: replace the placeholder emails, add Discord usernames and choose a channel per domain, and press
   **Send contact check** until each one is checked.
4. **Setup → Modules**: check owners, class pattern, resources and rankings.
5. Keep the domain in **Test** until the Operations team has watched a full week, then use **Settings → Testing → Go
   live**.

---

## Checklist

Tick each line when it is done. **Do not write secret values in this table**: for secrets write "in password manager".

| # | Item | Where to get it | Where to put it | Sandbox value | Production value | Done |
|---|---|---|---|---|---|---|
| 1 | Supabase project | supabase.com → New project | | | | ☐ |
| 2 | Supabase project URL | Project Settings → Data API | Vercel `VITE_SUPABASE_URL`; n8n Config `supabaseUrl` | | | ☐ |
| 3 | Supabase publishable key | Project Settings → API Keys | Vercel `VITE_SUPABASE_PUBLISHABLE_KEY` | | | ☐ |
| 4 | Supabase secret key (secret) | Project Settings → API Keys → Secret keys | n8n `Supabase secret key (<env>)` | in password manager | in password manager | ☐ |
| 5 | Database password and connection string (secret) | Connect → Session pooler | `.env.sandbox` or `.env.production` `DATABASE_URL` | in password manager | in password manager | ☐ |
| 6 | Tables and functions | `npx supabase db push` | Supabase | | | ☐ |
| 7 | Starting data | `supabase/seed.sql` (Production), Reset Sandbox data (Sandbox) | Supabase | | | ☐ |
| 8 | Environment and sign in domain | You decide | `npm run configure:<env> -w scripts` | Sandbox | Production | ☐ |
| 9 | Sandbox allowed Discord servers and email domains | Discord server ID; your domain | `.env.sandbox`, then configure | | not used | ☐ |
| 10 | Sign in hook | Authentication → Hooks | Before User Created → `public.hook_before_user_created` | | | ☐ |
| 11 | Email sign up switched off | Authentication → Sign In / Providers | Supabase | | | ☐ |
| 12 | Google Cloud project, Internal | console.cloud.google.com | | | | ☐ |
| 13 | Google sign in client ID and secret (secret) | Google Auth Platform → Clients | Supabase → Providers → Google | in password manager | in password manager | ☐ |
| 14 | Google client for n8n (secret) | Google Auth Platform → Clients | n8n `Gmail scheduling (<env>)` | in password manager | in password manager | ☐ |
| 15 | Service account key (secret) | IAM & Admin → Service Accounts → Keys | n8n `Google service account (<env>)` | in password manager | in password manager | ☐ |
| 16 | Shared drive and backup folder IDs | Google Drive address bar | n8n WF3 Upload to Google Drive | | | ☐ |
| 17 | Scheduling mailbox | Google Admin console | n8n Gmail sign in; app Sender email | | | ☐ |
| 18 | Discord server | Discord | | | | ☐ |
| 19 | Discord server ID | Right click server → Copy Server ID | App Connections; Sandbox allow list | | | ☐ |
| 20 | Discord bot token (secret) | Developer Portal → Bot | n8n `Discord bot (<env>)` | in password manager | in password manager | ☐ |
| 21 | Message Content Intent on | Developer Portal → Bot | | | | ☐ |
| 22 | Bot invited and can see channels | OAuth2 link in 4.2 | Discord server | | | ☐ |
| 23 | Admin, alert and testing channel IDs | Right click channel → Copy Channel ID | App Connections, Domains, Testing | | | ☐ |
| 24 | Poke secret (secret) | Password manager generator | n8n `Poke secret (<env>)`, Config `pokeKey`, Vercel `VITE_N8N_POKE_KEY` | in password manager | in password manager | ☐ |
| 25 | Workflows imported and published | `n8n/sandbox/`, `n8n/production/` | n8n | | | ☐ |
| 26 | WF2 confirm page address | n8n WF2 webhook | App Connections → Response page link | | | ☐ |
| 27 | WF4 poke address | n8n WF4 webhook | Vercel `VITE_N8N_POKE_URL`; n8n Config `pokeUrl` | | | ☐ |
| 28 | Error workflow set | n8n workflow Settings | WF1 to WF4 | | | ☐ |
| 29 | OpenAI key (optional, secret) | platform.openai.com → API keys | n8n `OpenAI (<env>)` | skip | in password manager | ☐ |
| 30 | Hosting project | Vercel Pro or Cloudflare Pages | | | | ☐ |
| 31 | Hosting variables | Tables in 7.2 | Vercel or Cloudflare | | | ☐ |
| 32 | App address | Vercel or Cloudflare Domains | Supabase URL Configuration; App link | | | ☐ |
| 33 | First checks | Part 8 | | | | ☐ |

---

## Your own computer (optional)

You need Docker Desktop and Node.js 22.

```bash
npm ci
```

```bash
npm run db:start
```

Copy `app/.env.example` to `app/.env.local` and use the local address and key that `db:start` prints (local ports are
5542x), `VITE_ALLOWED_EMAIL_DOMAIN=example.com` and `VITE_ENABLE_DEV_LOGIN=true`. Then:

```bash
node node_modules/vite/bin/vite.js app --config app/vite.config.ts --port 5173
```

Sign in with any `@example.com` address; the sign in link arrives in the local mail catcher at
<http://127.0.0.1:55424>.

Useful commands: `npm run db:test` (database tests), `npm test` (app tests), `npm run mock -- --race` (a full class
timeline without any accounts), `npm run check` (format, lint, types, tests and build).

**Windows and folder names with `&`:** npm's default Windows shell breaks on paths that contain `&`. If your folder
name has one, copy `.npmrc.windows-example` to `.npmrc` (it makes npm scripts run in Git Bash). `.npmrc` is not
committed.
