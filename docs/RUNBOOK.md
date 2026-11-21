# Runbook

What to check each day, how to stop messages fast, and what to do when something looks wrong. The app's own Help
(the **Help** link in the sidebar) explains every page step by step.

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
| The automatic check on Connections is old | WF1 is not published, n8n is down, or the Supabase project is paused | Publish WF1. Check n8n **Executions** (WF5 also posts errors in the admin alert channel). A free Supabase project pauses after a week without use: restore it in the Supabase dashboard. |
| Messages stay waiting to send | Messages are paused, WF4 is not running, or the Supabase key in n8n is wrong | Check for the red paused bar first. Run WF4 by hand in n8n. Check the n8n credential **Supabase secret key**. |
| Buttons in the app do not send at once | `VITE_N8N_POKE_URL` or `VITE_N8N_POKE_KEY` is wrong in the hosting settings | Messages still go within 5 minutes (WF4 runs on a schedule). Fix the hosting variables and deploy again. |
| A task says a Discord message was not delivered | The bot cannot post in the instructor's channel, or the channel was deleted | The task says exactly what to fix. Give the bot's role access to the channel, or choose a new channel for the instructor on **Setup, Instructors**. The email was still sent. |
| A task says an email bounced | Wrong email address | Fix it on **Setup, Instructors**. Discord is still used meanwhile. |
| An answer link says "This link isn't valid" | The link was copied only in part, or the answer page link is wrong | **Settings, Connections, Advanced: links** shows the answer page link. It must be the WF2 production address. Change it with `npm run configure:<env> -w scripts` (docs/SETUP_GUIDE.md, 1.4). |
| An instructor presses the button on the answer page and nothing happens | The answer page link points to the n8n test address (`/webhook-test/`) | Use the production address (`/webhook/respond`) and publish WF2. |
| Someone cannot sign in | Not a company Google account, or the Supabase redirect address is missing | Only company Google accounts work. Check Supabase, **Authentication, URL Configuration**. The refusal is in Activity history. |
| "This changed, reload" | Someone else saved the same record | Reload the page and make your change again. |
| Requests do not start for a class week | Setup is not finished (no owner, nobody can be asked, and so on) | **Needs your attention** says why. Fix it and asking starts at the next automatic check. |
| "Needs an instructor" | Everyone in the instructor order said no, did not reply or cannot be asked | Phone people, then open the class week and press **Assign and confirm instructor** or **Record a phone or chat confirmation**. Or add instructors to the module's instructor order: asking starts again by itself. |
| A written reply shows in Needs your attention | An instructor wrote instead of pressing a button | Read it and decide. Press **Reply** to answer them in their channel and by email. |

## After an outage

Nothing needs replaying. When n8n or Supabase comes back, the next automatic check catches up: missed reminders are
sent once, requests with no answer move on, and every message has its own key, so nothing is sent twice. Activity
history shows what ran.

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

The hourly check and the calls to WF4 run from the database once the clock is on (decision 281). See its state, the
scheduled jobs, whether the poke key is in Vault (yes or no only) and n8n runs this month:

```bash
npm run clock -w scripts -- status
```

`npm run clock -w scripts -- off` switches it off at once (for example if n8n runs look wrong); then publish the
schedule triggers of WF4 and WF1 again so n8n keeps working on its own schedule.

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

## Adding a new domain (no code)

Follow the Help guide **Setting up a new domain**: create the domain on **Setup, Domains**, choose its Discord server
and alert channel, add the operations team and leads, add modules with owners, class times and materials, add or check
instructors (people already in the app are reused), set each module's instructor order, review the settings on
**Settings, Automation**, then turn on testing and run the key steps with the practice clock on **Settings, Testing**.
Plan classes, watch for a week, then **Go live**.
