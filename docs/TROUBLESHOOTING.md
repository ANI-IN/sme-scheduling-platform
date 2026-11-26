# Troubleshooting

Find the symptom, then the likely cause and the fix. Setup: [SETUP.md](SETUP.md). Settings:
[CONFIGURATION.md](CONFIGURATION.md).

## Installing and running locally

| Symptom | Cause | Fix |
|---|---|---|
| `npm ci` warns about an unsupported engine | Node version too old | Install Node 22.22.2+, 24.15+ or 26+ |
| npm warns that an install script was not run (`esbuild`) | Newer npm asks before running install scripts | If the app fails to build, run `npm install-scripts approve esbuild` and `npm ci` again |
| Scripts fail on Windows with a syntax or path error | npm used the Windows command prompt | Copy `.npmrc.windows-example` to `.npmrc` |
| `db:start` fails | Docker Desktop is not running, or ports 5542x are taken | Start Docker; stop other Supabase projects using those ports |
| Database commands say the container does not exist | The local stack is stopped | `npm run db:start` |
| `db reset` fails right after stopping a test run | Containers still shutting down | Wait a few seconds and run it again |
| Browser tests cannot start a browser | The test browser is missing | `npx playwright install chromium` |
| Browser tests time out on a busy computer | Machine load | Close other work; `E2E_PAGE_WORKERS=1` |
| "The app is not configured yet" | No `app/.env.local`, or missing address or key | See [SETUP.md](SETUP.md#5-configure-the-web-app), restart `npm run dev` |

## Signing in

| Symptom | Cause | Fix |
|---|---|---|
| No email sign in box locally | `VITE_ENABLE_DEV_LOGIN` is not `true`, or a production build | Set it in `app/.env.local` and restart |
| The local sign in link never arrives | Looking in your real mailbox | Open the mail catcher at `http://127.0.0.1:55424` |
| "Not allowed to sign in" on a hosted app | Outside the company domain, or not on the beta list | An admin adds the person on Settings, Admin |
| Google sign in returns to an error page | Redirect address missing | Supabase URL configuration and the Google client's origins |
| Someone cannot change a setting | Admins only | Ask an admin; make the first one with `npm run admins` |

## Messages and automation

| Symptom | Cause | Fix |
|---|---|---|
| Messages stay waiting | Messages paused, clock off, WF4 unpublished, or a wrong key in n8n | Check the red paused bar; `npm run clock -w scripts -- status`; check WF4 executions and credentials |
| WF4 refuses calls (403) | Webhook key differs | The `Poke secret` credential and Vault `n8n_poke_key` must hold the same value |
| A task "Check if a message arrived" | n8n took a message and never reported it | Look in the channel or mailbox, then **It arrived, mark as sent** or **Send again** |
| Discord message not delivered | The bot cannot post there, or the channel is gone | Do what the task says; choose a new channel on Setup, Instructors |
| Direct messages or posts stopped for a domain | No server chosen, or the server is not approved for it | Settings, Connections |
| An email bounced | Wrong address | Fix it on Setup, Instructors |
| A typed reply does not show | No open conversation, reply reading slowed down, or sent elsewhere | Replies count only to the `+scheduling` address or in the instructor's own channel; run WF4 by hand |
| The answer page button does nothing | The test webhook address was configured, or WF2 is unpublished | Use the production webhook address, configure again, publish WF2 |
| "This link isn't valid" | Link copied in part, or a wrong address | Settings, Connections, Advanced: links |
| No daily summary | WF3 unpublished or no admin alert channel | Publish WF3; choose the channel |
| Automatic check is old | Clock off or the Supabase project paused | `npm run clock -w scripts -- status`; restore the project |
| "This changed, reload" | Someone else saved first | Reload and redo the change |
| Requests do not start | Setup incomplete for the week | Needs your attention says what is missing |

## When a service is down

| Down | Still works | Then |
|---|---|---|
| Discord | The app; email copies still go | Press **Send again** on failed messages |
| Gmail | The app; Discord copies still go | Press **Send again** on failed messages |
| n8n | The app and the clock | Messages wait and go once when it returns; pause messages if it lasts hours |
| Supabase | Nothing | Check its status page; a paused free project can be restored |
| App host | The database and automation | Instructors can still answer; roll back the app |

Nothing needs replaying after an outage: the next check catches up and nothing is sent twice.

## Scripts for a hosted database

| Message | Fix |
|---|---|
| `Refusing: set SUPABASE_PROJECT_REF` | Add your project ID to `.env.production` |
| `Refusing: DATABASE_URL is not the project ...` | The connection string is for another project |
| "already running" from the backup | Another backup runs; wait for it |
| `Copy n8n/instance.example.json ...` | Create `n8n/instance.json` before exporting |
