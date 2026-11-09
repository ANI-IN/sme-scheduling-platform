# Runbook

## Daily checks (5 minutes)
1. **Admin Discord channel:** the daily heartbeat (T15) arrived this morning. No heartbeat = something is down (see below).
2. **App → Settings → System:** last hourly run is less than ~1 hour ago and says `ok`; "waiting to send" is small;
   failures in the last 24 h are explained.
3. **App → Needs Attention:** no urgent items older than a few hours without "I'm on it".
4. **Test mode:** the yellow bar is only on domains that should be in test. The digest also says which domains are in
   TEST MODE.

## Kill switch (stop all instructor messages)
- **Turn on:** Settings → System → **Pause all outreach (kill switch)** → confirm. No instructor is messaged anywhere;
  requests stop moving on; team alerts continue. Queued instructor messages are held, not lost.
- **Turn off:** same place → **Turn kill switch off**. Held messages and due steps go out at the next run.
- The heartbeat reminds the admin every day while it is on.
- To stop one domain only: Modules → domain status **Paused**. To stop one module week: class drawer → **Pause outreach**.

## Common problems
| Symptom | Likely cause | Fix |
|---|---|---|
| No heartbeat this morning | n8n down, WF3 unpublished, or Discord admin channel wrong | Open n8n → Executions. Check WF3 is published and its Config node. Check Settings → System → Admin channel ID. |
| "Last hourly run" is old | WF1 not published / n8n down / Supabase paused | Publish WF1; check n8n Executions for errors (WF5 also posts them in the admin channel). Supabase free projects pause after a week of no activity — restore it in the Supabase dashboard. |
| Messages stay "waiting to send" | WF4 not running, wrong Supabase secret key, kill switch on | Check kill switch; run WF4 manually; check the "Supabase secret key" credential. |
| App buttons don't send right away | `VITE_N8N_POKE_URL`/`VITE_N8N_POKE_KEY` wrong | Messages still go within 5 minutes (WF4 schedule). Fix the Cloudflare env and redeploy. |
| "Message failed: … via Discord" (Missing Access / Unknown Channel) | Bot can't see the instructor channel, or the channel link changed | Give the bot role access to the channel; fix the channel link on the instructor (then send a test message). Email was still sent. |
| "Email bounced" | Wrong email address | Fix it on the instructor; Discord is still used meanwhile. |
| Confirm link shows "This link isn't valid" | Link copied incompletely, or Response page URL wrong | Check Settings → System → Response page URL is the WF2 production URL. |
| Instructor says the page does nothing when they press the button | Response page URL points to the test webhook (`/webhook-test/`) | Use the production URL (`/webhook/respond`) and publish WF2. |
| Someone can't sign in | Not a company account, or Supabase redirect URL missing | Only `@company` accounts work. Check Supabase → Authentication → URL Configuration. |
| "This changed — reload" | Someone else saved the same record | Reload the page and redo your edit. |
| Outreach not starting for a week | Readiness check failing (no owner, nobody eligible…) | Needs Attention shows the reason; fix it and it starts at the next run (or Settings → Run check now in test mode). |
| "Needs instructor" | Everyone in the ranking declined, didn't reply or can't be asked | Phone people; **Assign manually** or **Record offline confirmation**; or add instructors to the ranking (outreach resumes automatically). |
| Typed reply in Needs Attention | Instructor wrote instead of tapping | Read it and decide; reply in their channel; use the item's buttons. |

## After an outage
Nothing needs replaying. When n8n or Supabase comes back, the next hourly run catches up: missed reminders are sent once,
expired requests move on, and unique message keys prevent duplicates. Check History → System for the run summaries.

## Backups
WF3 saves `sme-backup-YYYY-MM-DD.json` to the Google Drive folder every night (all setup and schedule tables). History
can also be exported as CSV from the History tab. Supabase's paid plan adds automatic backups when the whole team depends
on the system.

## Adding a new domain (no code)
Follow PRD §21.2: create the domain (Draft) in Modules → set alert channel, leads, ops → add modules, owners, pattern,
resources → add/verify instructors (existing people are reused) → rankings → review settings → switch to **Test** and run
the key scenarios with the test clock → plan classes → shadow for a week → **Live**.
