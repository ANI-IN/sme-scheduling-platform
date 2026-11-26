# Configuration

Every setting: whether it is needed, whether it is secret and where it goes. How to use them in a deployment:
[DEPLOYMENT.md](DEPLOYMENT.md).

## Secrets

Never commit a secret, paste it into an issue or chat, or put it in a `VITE_` variable (the browser can read those).
Keep secrets in your password manager and put them only where this page says. Git ignores these files: `.env`,
`.env.production`, `app/.env.local`, `.npmrc`, `n8n/instance.json` and database dumps.

## Mandatory and optional integrations

| Integration | Needed for local work and tests | Needed in a real deployment |
|---|---|---|
| Supabase (hosted project) | No (local stack) | Yes |
| Google sign in | No (email link on the local stack) | Yes |
| n8n | No | Yes, to send messages |
| Discord bot | No | Yes, for Discord messages |
| Gmail mailbox | No | Yes, for email |
| Google Drive | No | Optional (nightly backup) |
| Static hosting such as Vercel | No | Yes (any static host) |

## Web app: `app/.env.local` or your host's variables

| Variable | Needed | Secret | Meaning |
|---|---|---|---|
| `VITE_SUPABASE_URL` | Yes | No | The Supabase API address. Local: `http://127.0.0.1:55421` |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Yes | No | The publishable key (`sb_publishable_...`) |
| `VITE_ALLOWED_EMAIL_DOMAIN` | Recommended | No | Preselects the company account on Google's screen. The database decides access |
| `VITE_DISCORD_CLIENT_ID` | Optional | No | The bot's application ID; shows the invite link on Settings, Connections |
| `VITE_ENABLE_DEV_LOGIN` | Local only | No | `true` shows the email link sign in. Ignored by production builds |

`VITE_COMPANY_EMAIL_DOMAIN` is accepted as an older name of `VITE_ALLOWED_EMAIL_DOMAIN`.

## Scripts: `.env.production`

Read by `backup`, `clock`, `admins`, `configure:production` and `discord:production`. Copy `.env.example`.

| Variable | Needed by | Secret | Meaning |
|---|---|---|---|
| `DATABASE_URL` | All of them | **Yes** | Connection string (Supabase, Connect, Session pooler, with the password) |
| `SUPABASE_PROJECT_REF` | `backup`, `clock` | No | Your project ID; these scripts refuse any other database |
| `ALLOWED_EMAIL_DOMAIN` | `configure:production` | No | Whose Google accounts may sign in |
| `APP_ENVIRONMENT` | `configure:production` sets it | No | `Production` when hosted. `Development` is refused for a database not on your computer |
| `RESPONSE_BASE_URL` | `configure:production` | No | The WF2 webhook address used in answer buttons (https) |
| `APP_BASE_URL` | `configure:production` | No | The app's address used in links (https) |
| `BACKUP_DIR` | `backup` (optional) | No | Where backups go. Default: `Backups/sme-scheduling` in your home folder |
| `DISCORD_BOT_TOKEN` | `discord:production` (optional) | **Yes** | Only to run the Discord checks from your computer |
| `SANDBOX_ALLOWED_DISCORD_SERVERS`, `SANDBOX_ALLOWED_EMAIL_DOMAINS` | Not used | No | Allow lists of the retired Sandbox environment; leave empty |

## Local Supabase: `supabase/config.toml`

Ports 5542x, Postgres 17, the migrations and both seed files, and the sign up hook. To try Google sign in locally, set
`enabled = true` under `[auth.external.google]` and provide `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID` and
`SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` (secret) as environment variables.

## Test settings (all optional)

| Variable | Used by | Meaning |
|---|---|---|
| `E2E_PAGE_WORKERS` | `npm run e2e` | Page tests at the same time (default 2) |
| `E2E_KEEP_STACK` | `npm run e2e` | `1` keeps the test stack running (same as `--keep`) |
| `TEST_DATABASE_URL` | Test stack scripts | Overrides the test database address |
| `DB_CONTAINER` | `db:test` | The database container (default `supabase_db_sme-scheduling`) |
| `APP_URL`, `SHOT_EMAIL` | Picture scripts | App address and the account pictured |
| `CI` | Browser tests | Set by continuous integration |

## Automation: `n8n/instance.json`

Copy `n8n/instance.example.json`. Used only by `npm run n8n-export -w scripts`.

| Key | Meaning |
|---|---|
| `key` | Any short word; keeps webhook IDs the same between exports |
| `title`, `tag` | Shown in workflow names, and the workflows' tag |
| `pathPrefix` | Put in front of webhook paths; may be empty |
| `supabaseUrl` | Your Supabase API address |
| `n8nUrl` | Your n8n address |
| `backupFolderId` | Google Drive folder for backups |
| `processedLabelId` | ID of the Gmail label that marks handled replies |
| `adminChannelId` | Discord channel used when the database cannot be reached |
| `replyAddress` | Your mailbox with `+scheduling` before the `@` |
| `credentials` | The name of each credential in your n8n |

## n8n credentials

| Name in the base files | Type | Secret value |
|---|---|---|
| `Supabase secret key` | Header Auth, name `apikey` | The Supabase secret key (`sb_secret_...`) |
| `Poke secret` | Header Auth, name `x-poke-key` | A long random string, also stored in Supabase Vault |
| `Discord Bot` | Discord Bot API | The bot token |
| `Gmail` | Gmail OAuth2 | Sign in with Google in n8n |
| `Google Drive Backups` | Google Drive OAuth2 | Sign in with Google in n8n |

## Supabase dashboard

| Setting | Value |
|---|---|
| Authentication, Providers | Google on (client ID and secret); Email off |
| Authentication, Hooks | Before User Created: function `public.hook_before_user_created` |
| Authentication, URL configuration | Site URL and redirect URLs of your app |
| Vault | Secret `n8n_poke_key` with the same value as the `Poke secret` credential |

## Discord

The bot needs View Channels, Send Messages, Embed Links and Read Message History, plus the Server Members Intent and
the Message Content Intent. Servers, channels and people are chosen inside the app; nobody types Discord IDs.

## Settings inside the app

| Page | Settings |
|---|---|
| Settings, Admin | Who may sign in, the beta list, who may receive messages, allowed email domains, daily email limit, admins |
| Settings, Automation | Timing and planning rules per domain or cohort |
| Settings, Messages | Message texts |
| Settings, Testing | Testing channel and email, practice clock |
| Settings, Connections | Discord servers, admin alert channel, sender name and email |
