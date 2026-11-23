# Glossary and wording rules

The words the app uses, and the rules every screen follows. Text written by the database
(task titles, history, reasons) is translated in the app by `app/src/lib/plain.ts` and
`app/src/lib/historyText.ts`, so the database keeps its own wording.

Check the rules with:

```bash
npm run scan-text -w scripts
```

## Rules

- **No dashes and no hyphens** in anything a user reads. Use "to" for ranges ("3 to 10 days",
  "9:00 AM to 1:00 PM PST"), a colon to join a name and a detail ("API Design: Live class"), and
  rewrite hyphenated words ("time change", "sign in link", "not urgent").
- **No "e.g."**: write "for example".
- **No internal names** (WF2, n8n, UUID, payload, token, kill switch, heartbeat, hourly check,
  seed, ranking). The Connections page is the one exception, because it is the technical setup.
- **Sentence case** for labels, buttons, headings and tabs ("Plan classes", not "Plan Classes").
- **Every empty state says what to do next**, and every dangerous action asks first and says
  what will happen.
- An empty value is shown as "Not set", "Not yet" or "Nobody yet", never as a dash.
- **One set of status words** for a class week (see Class week statuses below).

## Terms

| Use | Instead of | Meaning |
| --- | --- | --- |
| Needs your attention | Needs attention, attention items | Tasks the automation could not finish on its own |
| Task | Attention item, checklist item | Something a person on the team needs to do |
| Class week | Module week | One module taught in one week (usually a live class and an assignment review) |
| Instructor order | Ranking, priority list | The order instructors are asked for a module |
| Primary instructor, Backup 1, Backup 2 | Rank 1, rank 2 | Places in the instructor order |
| Chosen list | Manual mode, manual queue | Instructors picked by hand for one class week |
| Instructor requests | Outreach | Asking instructors to teach, one at a time |
| Ask the next instructor | Skip to next | Withdraw the current request and ask the next person |
| Reminder before class | Check in, check-in | The message a confirmed instructor gets before class |
| Setup check | Readiness check | The check that a module has everything it needs before we ask instructors |
| Contact details checked | Verified | The instructor answered a contact check message |
| Contact check | Verification message, verified, test message | An optional message that confirms an instructor's Discord and email work; instructors are asked whether or not they are checked |
| Pause all messages | Kill switch | Stop every message from the app at once |
| Practice clock | Test clock, simulated time | A pretend "now" for a domain in testing |
| Automatic check | Hourly check, cron | The regular run that sends messages and moves requests on |
| Operations team | Ops, ops contacts | The people who handle tasks, failed messages and written replies |
| Leads | Escalation contacts | People told when a task stays open too long |
| Activity history | History, audit log | Every change, message and decision, newest first |
| Needs real details | Placeholder, replace | A record created during setup that still has made up details |
| Testing | Test mode | A domain whose messages go only to the testing channel and email |
| Release instructor | Release booking | Tell a confirmed instructor they are no longer needed and ask others |
| Download as spreadsheet | Export CSV | Save the list as a file |
| Not in use | Inactive | An instructor or team member that is kept but not used |
| Draft (module) | Inactive, not in use | A module being set up: it is skipped when planning and nobody is asked |
| Live (module) | Active, in use | A module whose instructors are asked |
| Ready (module) | | A module with class times, an owner and at least 1 instructor (a setting) in its instructor order |
| Welcome message | M22 | The short message a new instructor gets once by email and once on Discord per domain |

## Class week statuses

A class week always shows one of these statuses, in these words, everywhere a person reads it: the Schedule
board and its Legend, the side panel, Upcoming classes, Instructor requests, Home, filters, spreadsheet downloads
and messages to the team. The words live in `WEEK_STATUS` in `app/src/lib/status.ts` (the board's icons and Legend
sentences are in `app/src/pages/boardBadges.ts`), and the database writes them with `private.week_status_text`.
The database keeps its own status codes (Planned, NotReady, Ready, Asking, NeedsInstructor), which people never see.

| Status | Meaning |
| --- | --- |
| Confirmed | An instructor said yes to this class week. |
| Waiting for an answer | An instructor was asked and has not answered yet. |
| Needs instructor | Nobody is confirmed or being asked, so you need to choose an instructor. |
| Proposed time | The instructor proposed another time, which you accept or reject. |
| Not asked yet | Nobody was asked yet, and the Primary instructor is asked first. |
| Setup incomplete | Something is missing, such as class times or an instructor order, so nobody can be asked yet. |
| Paused | Requests for this class week are paused, so nobody is asked. |
| Cancelled | This class week or class will not take place. |
| Completed | Every class of this week has finished. |
| Break | The cohort has a break this week, so it has no class week. |

At risk is not a status: it is a badge (and a filter) on a class week that may not have an instructor in time.

Not used: "Asking", "Asking now", "Being asked" (use Waiting for an answer), "Ready to ask", "Not started yet",
"Not started" (use Not asked yet), "Setup not finished" (use Setup incomplete), "Needs an instructor" (use Needs
instructor), "Requests paused" (use Paused) and "Waiting for a reply" (use Waiting for an answer). The wording scan
flags them as labels; the verb in a sentence ("We are asking the next instructor") is fine.

## Message names

The messages the system sends are named by what they do, not by their code:
request to teach, reminder about the request, confirmation, class time change, reminder before
class, final reminder before class, cancellation note, help request receipt, reply, contact
check. The full list is `messageName` in `app/src/lib/plain.ts`.

## Proposed (not done)

Checked on 22 November 2026: the message templates (`private.template_defaults`) contain no dashes. The answer
pages still have four sentences with a dash ("Already recorded — thank you!" twice, "we'll let the team know —
they'll be in touch", "Great — thanks!"). Rewording them changes text the database sends, so it stays under
"Proposed logic changes" in docs/DECISIONS.md (P1).
