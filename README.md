# SME Scheduling & Outreach Platform

Finds, confirms and checks in instructors for every class, with no double bookings and no "sorry, someone else got
it" messages. Built from [docs/PRD.md](docs/PRD.md) (v3.0).

- **Database (Supabase/Postgres)** — the single source of truth _and_ all decision logic (`supabase/migrations`).
- **n8n** — input/output only: runs the hourly engine, sends the queued Discord/Gmail messages, serves the confirm pages,
  reads replies (`n8n/`).
- **Web app (React + Vite, Cloudflare Pages)** — 7 tabs for ops (`app/`).

| Doc                                                                                                          | For                                                                                               |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)                                                                   | Sandbox and Production setup: Supabase, Google, Gmail, Discord, n8n, Vercel or Cloudflare, OpenAI |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md)                                                                     | One page for ops on the 7 tabs                                                                    |
| [docs/RUNBOOK.md](docs/RUNBOOK.md)                                                                           | Daily checks, kill switch, common problems                                                        |
| [docs/HANDOFF.md](docs/HANDOFF.md)                                                                           | What is built, how it is tested, what still needs real credentials                                |
| [docs/PLAN.md](docs/PLAN.md) · [docs/DECISIONS.md](docs/DECISIONS.md) · [docs/PROGRESS.md](docs/PROGRESS.md) | Architecture, decisions, status                                                                   |
| [n8n/README.md](n8n/README.md)                                                                               | Importing the 5 workflows and their credentials                                                   |

Quick start (local, needs Docker + Node 20+): `npm install`, `npm run db:start`, copy `app/.env.example` to
`app/.env.local`, `npm run dev -w app`. Checks: `npm run check`, `npm run db:test`, `npm run mock -- --race`.
