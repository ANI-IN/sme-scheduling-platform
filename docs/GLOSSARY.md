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
| Contact check | Verification message | A message that confirms an instructor's Discord and email work |
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
| Not in use | Inactive | A module, instructor or team member that is kept but not used |

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
