# SME Scheduling & Outreach Platform

Finds, confirms and checks in instructors for every class, with no double bookings and no "sorry, someone else got
it" messages. Built from [docs/PRD.md](docs/PRD.md) (v3.0).

- **Database (Supabase and Postgres):** the single source of truth and all decision logic (`supabase/migrations`).
- **n8n:** input and output only. It runs the automatic check, sends the queued Discord and Gmail messages, serves the
  answer pages, reads replies and runs the Discord checks (`n8n/`).
- **Web app (React and Vite, hosted on Vercel or Cloudflare Pages):** Home, Upcoming classes, Instructor requests,
  Setup, Settings and Activity history, with Help built in (`app/`).

| Doc                                                                                                          | For                                                                                                         |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)                                                                   | Production setup (the one environment): Supabase, Google, Gmail, Discord, n8n, Vercel or Cloudflare, OpenAI |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md)                                                                     | One page overview of the app (the full guide is the in-app Help)                                            |
| [docs/RUNBOOK.md](docs/RUNBOOK.md)                                                                           | Stopping all messages, daily checks, common problems                                                        |
| [docs/HANDOFF.md](docs/HANDOFF.md)                                                                           | What is built, how it is tested, what still needs real credentials                                          |
| [docs/PLAN.md](docs/PLAN.md) · [docs/DECISIONS.md](docs/DECISIONS.md) · [docs/PROGRESS.md](docs/PROGRESS.md) | Architecture, decisions, status                                                                             |
| [n8n/README.md](n8n/README.md)                                                                               | Importing the 6 workflows and their credentials                                                             |

Quick start (local, needs Docker and Node 22): `npm ci`, `npm run db:start`, copy `app/.env.example` to
`app/.env.local`, `npm run dev -w app`. Checks: `npm run check`, `npm run db:test`, `npm run mock -- --race`,
`npm run e2e`. The test results are in [docs/TEST_REPORT.md](docs/TEST_REPORT.md).
