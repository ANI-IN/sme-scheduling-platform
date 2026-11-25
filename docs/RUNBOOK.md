# Runbook

What to check each day, how to stop messages fast, and what to do when something looks wrong. The app's own Help
(the **Help** link in the sidebar) explains every page step by step.

There is one environment, **Production** (since 22 November 2026). It is the old Sandbox under a new name: the same
Supabase project `abcdefghijklmnopqrst`, the same n8n instance and the same app <https://your-app.vercel.app>.
There is no Sandbox any more. The n8n workflows are named `[Production] WF1 Hourly engine` and so on. Some internal
names keep the word Sandbox on purpose, because renaming them could break things: the n8n credentials (for example
`Supabase Sandbox`), the n8n tag `Sandbox`, the webhook paths (for example `/webhook/sandbox-sme-poke`) and the
folder `n8n/sandbox/`. The script commands below read `.env.production`, the live settings file. The database refuses
any reset.

## Stop all messages to instructors (do this first in an emergency)

1. Open your account menu at the bottom of the sidebar (your email address).
2. Press **Pause all messages** and confirm.

No instructor is messaged anywhere and requests stop moving on. Team alerts still go out. Messages that were waiting
are kept, not lost. A red bar shows on every page while messages are paused.

To start again, press **Turn messages back on** in the red bar and confirm. Waiting messages go out at the next
automatic check, once each.

You can also pause from the bottom of **Settings, Automation**, or from **Settings, Connections**.

- **Stop one domain only:** **Setup, Domains**, open the domain, set its **Status** to **Paused**.
- **Stop one class week only:** open the class week (on **Upcoming classes** or **Instructor requests**) and press
  **Pause requests**.

## Daily checks (5 minutes)

1. **Admin alert channel in Discord:** the daily system summary arrived this morning. If it did not, something is
   down (see the table below).
2. **Settings, Connections, Connection health:** the automatic check ran less than about an hour ago and says it
   worked. **Messages waiting to send** is small. Failures in the last 24 hours have a reason in Activity history.
3. **Home, Needs your attention:** no urgent task older than a few hours without someone on it.
4. **Testing:** only the domains that should be tested show the testing bar. The daily summary also lists them.

## Common problems

| What you see | Likely cause | What to do |
|---|---|---|
| No daily system summary this morning | n8n is down, WF3 is not published, or no admin alert channel is chosen | Open n8n, **Executions**. Check WF3 is published and its Config node. Choose the admin alert channel on **Settings, Connections**. |
| The automatic check on Connections is old | The database clock is off, or the Supabase project is paused | The clock runs the automatic check every hour (job `sme-engine-hourly`). Run `npm run clock -w scripts -- status`. If the clock is off, switch it on, or turn WF1's schedule trigger back on in n8n and publish WF1 as a stopgap. A free Supabase project pauses after a week without use: restore it in the Supabase dashboard. |
| Messages stay waiting to send | Messages are paused, the clock cannot poke WF4, WF4 is not published, or the Supabase key in n8n is wrong | Check for the red paused bar first. Run `npm run clock -w scripts -- status`: the last result says why a poke did not go. Run WF4 by hand in n8n and check its **Executions**. Check the n8n credential `Supabase Sandbox` (the internal name of the Production Supabase key). |
| Messages take more than a minute to leave | The database could not poke WF4 (n8n down or the poke key in Vault wrong) | Messages still go out at WF4's safety run every hour. Run `npm run clock -w scripts -- status`: the last result says why a poke did not go. Since decision 334 the app never calls n8n itself; the Vercel variables VITE_N8N_POKE_URL and VITE_N8N_POKE_KEY are not used. |
| A task "Check if a message arrived" | n8n took the message 15 minutes ago and never reported back (n8n stopped mid run, or a time out) | Nothing is sent again by itself (decision 341). Look for it in the channel or mailbox, then press **It arrived, mark as sent** or **Send again**. Several at once: check WF4's **Executions** in n8n for a failed or stopped run. |
| A typed reply does not show in Needs your attention | No conversation is open, reply reading slowed down, or the reply went elsewhere | WF4 reads replies about every 10 minutes while the app sent that instructor something in the last 3 days (every 20 minutes above 8,000 n8n runs in the month, and only when WF4 runs for other work above 9,300). Email replies count only when sent to the +scheduling reply address; Discord replies only in the instructor's own channel. Run WF4 by hand in n8n to read at once. |
| A task says a Discord message was not delivered | The bot cannot post in the instructor's channel, or the channel was deleted | The task says exactly what to fix. Give the bot's role access to the channel, or choose a new channel for the instructor on **Setup, Instructors**. The email was still sent. |
| A task says an email bounced | Wrong email address | Fix it on **Setup, Instructors**. Discord is still used meanwhile. |
| An answer link says "This link isn't valid" | The link was copied only in part, or the answer page link is wrong | **Settings, Connections, Advanced: links** shows the answer page link. It must be the WF2 production address. Change it with `npm run configure:production -w scripts` (docs/SETUP_GUIDE.md, 1.4). |
| An instructor presses the button on the answer page and nothing happens | The answer page link points to the n8n test address (`/webhook-test/`) | Use the n8n production address (`/webhook/sandbox-respond`; the path keeps its name) and publish WF2. |
| Someone cannot sign in | They are not on the beta list, or the Supabase redirect address is missing | Only people on the beta list can sign in: an admin adds them on **Settings, Admin**. Check Supabase, **Authentication, URL Configuration**. The refusal is in Activity history. |
| "This changed, reload" | Someone else saved the same record | Reload the page and make your change again. |
| Requests do not start for a class week | Setup is not finished (no owner, nobody can be asked, and so on) | **Needs your attention** says why. Fix it and asking starts at the next automatic check. |
| "Needs an instructor" | Everyone in the instructor order said no, did not reply or cannot be asked | Phone people, then open the class week and press **Assign and confirm instructor** or **Record a phone or chat confirmation**. Or add instructors to the module's instructor order: asking starts again by itself. |
| A written reply shows in Needs your attention | An instructor wrote instead of pressing a button | Read it and decide. Press **Reply** to answer them in their channel and by email. |

## When a service is down

| Down | What still works | What to do |
|---|---|---|
| Discord | Everything in the app; email copies of every instructor message still go | Nothing. Discord messages that failed show **Message failed** with **Send again**; press it when Discord is back. |
| Gmail (sending) | Everything in the app; Discord copies still go | Nothing. Failed emails show **Message failed**; press **Send again** when Gmail is back. Gmail allows about 2,000 messages a day on Workspace (500 on a free account). |
| n8n | The app, the database clock and every rule | Messages and Discord checks wait (shown as waiting, never lost). When n8n is back, WF4 sends them at its next run; nothing is sent twice. If it lasts hours, press **Pause all messages** so nothing out of date goes when it comes back, then check the waiting list before turning messages back on. |
| Supabase | Nothing: the app cannot load | Check status.supabase.com. A free project pauses after a week without use: restore it in the dashboard. Nothing needs replaying afterwards. |
| Vercel (the app) | The database, the clock and n8n keep sending and reading answers | Instructors can still answer (the answer page is served by n8n). Roll back to the previous deployment if a deploy caused it (below). |

## After an outage

Nothing needs replaying. When n8n or Supabase comes back, the next automatic check catches up: missed reminders are
sent once, requests with no answer move on, and every message has its own key, so nothing is sent twice. Activity
history shows what ran.

## Hosting

The app is hosted on Vercel's free Hobby plan, which is for non commercial use. Cloudflare Pages is the free
alternative the app already supports: both `vercel.json` and Cloudflare Pages work (docs/SETUP_GUIDE.md, part 7).
Hosting is not changed for now.

## Backups

WF3 saves `sme-backup-YYYY-MM-DD.json` to the shared Google Drive folder every night (every setup and schedule table).
Activity history can also be downloaded as a spreadsheet from **Activity history**. Supabase's paid plan adds automatic
backups when the whole team depends on the app.

### Before any change to the live database (Release 3, decision 274)

1. Back up and verify (Docker Desktop must be running, for the local Supabase stack):

   ```bash
   npm run backup -w scripts -- --label before-<milestone>
   ```

   It refuses any project but `abcdefghijklmnopqrst`, saves the whole database (structure and data) to
   `C:\Users\you\Backups\sme-scheduling\` with the date in the name, restores it into a local throwaway database
   and compares the row count of every table (saved next to it as `.counts.txt`). It only reads the live database.
2. Every migration from Release 3 has a rollback file in `supabase/rollback/`, checked locally with:

   ```bash
   npm run check-rollbacks -w scripts
   ```

### The database clock (Release 3, M1)

The clock's run log keeps the last 7 days: job `sme-run-log-purge` deletes older runs every night at 21:15 UTC
(decision 333).

The clock has been on since 22 November 2026, 17:36 UTC (decision 281). `pg_cron` in the database runs the automatic
check itself (job `sme-engine-hourly`, at minute 30 of every hour), and the job `sme-clock` (every 2 minutes) pokes
WF4 only when there is work, and about every 10 minutes to read replies while a conversation is open (every 30
minutes from 5,000 n8n runs in the month, every hour from 6,500, none from 8,000). Typed replies show in the app within about 10 minutes.

- **Since 23 November 2026, 12:48 UTC** (the owner, after the urgent fixes went live): WF1 is unpublished, with its
  schedule trigger off, because the database's own hourly job does its work. WF4 runs on pokes (the database pokes it
  within seconds for every queued message and Discord check, its clock every 2 minutes for other work) plus a safety
  run every hour. WF2 (the answer pages), WF3 (daily at 09:00 IST) and WF5 (the error workflow) do not change.
  After importing the base files again, switch WF1's trigger off and leave WF1 unpublished: the base file still has it.

See the clock's state, the scheduled jobs, whether the poke key is in Vault (yes or no only), the last poke and n8n
runs this month:

```bash
npm run clock -w scripts -- status
```

`npm run clock -w scripts -- off` switches it off at once (for example if n8n runs look wrong); then turn the schedule
triggers of WF1 and WF4 back on and publish both workflows again, so n8n keeps working on its own schedule.
n8n/README.md has the details.

### Rolling back a deploy that failed its live checks

Roll back first, then fix locally:

- **App:** `npx vercel@65.14.0 rollback` (the previous deployment comes back in seconds).
- **n8n:** open each changed workflow, restore its previous version from the version history, publish it.
- **Database:** pause all messages, then run the migration's rollback file against the live database (in the Supabase
  SQL editor, or with `psql` and the connection string from your local settings file). Remove the migration's row from
  `supabase_migrations.schema_migrations` so it can be applied again after the fix.
- **Last resort, if a rollback file cannot run:** restore the backup taken before the deploy with `pg_restore --clean`
  into the live database. Anything done since the backup is lost, so do it only after pausing all messages and telling
  the testers.
- **The switch to Production:** `npm run configure:sandbox -w scripts` sets the database back to the old Sandbox rules.
  It is kept only as this rollback, and it also reads `.env.production`.

### Admins (Release 3, M2)

- `npm run admins -w scripts -- list` shows the admins. `add <email>` makes a signed in team member an admin, and
  `remove <email>` removes admin rights (never the last admin). Each change is in Activity history as "Setup command".
- Run `add` with your own address right after the M2 deploy: until then nobody is an admin, so nobody can change
  Pause all, the beta list or the Discord server approvals. After that, admins manage each other on Settings, Admin.

### Clearing the demo data (Release 3, M5, done)

The demo data was cleared once on 22 November 2026, and `npm run clear-demo` is removed. The hosted app starts empty
and each tester sets up their own domain; there is no demo data to load and no reset.

## Adding a new domain (no code)

Follow the Help guide **Setting up a new domain**: create the domain on **Setup, Domains**, choose its Discord server
and alert channel, add the operations team and leads, add modules with owners, class times and materials, add or check
instructors (people already in the app are reused), set each module's instructor order, review the settings on
**Settings, Automation**, then turn on testing and run the key steps with the practice clock on **Settings, Testing**.
Plan classes, watch for a week, then **Go live**.
