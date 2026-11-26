# Development

How the code is organised and how to change it safely. Set up first: [SETUP.md](SETUP.md). Tests:
[TESTING.md](TESTING.md).

## Layout

```text
app/                 the web app (Vite, React, TypeScript)
  src/pages/         one file per screen (setup/ and settings/ for those menus)
  src/components/    shared interface pieces
  src/lib/           data access and pure logic, with unit tests next to it
  src/help/          the in app guides (Markdown)
  public/help/       pictures used by the guides
supabase/
  migrations/        the database: tables, rules, functions (applied in name order)
  rollback/          one file per migration since the third release, undoing it
  tests/database/    pgTAP tests; tests/helpers/ and tests/fixtures/ support them
  seed.sql           runs everywhere; seed.local.sql only on your computer
n8n/                 the workflow source files and instance.example.json
scripts/src/         local stacks, test data, checks and commands for a hosted database
e2e/                 Playwright tests
docs/                documentation
```

## Daily workflow

1. Create a branch from `main`.
2. Write a failing test: pgTAP for a rule, Vitest for logic, Playwright for a screen.
3. Change the database with a **new** migration. Never edit a migration that has been applied anywhere.
4. Change the app.
5. Run `npm run check`, `npm run db:test`, `npm run check-rollbacks -w scripts`, then the browser tests for the area.
6. Open a pull request; the checks run on GitHub.

## Database changes

- Name migrations `YYYYMMDDHHMMSS_short_name.sql` in `supabase/migrations/`, after the newest one.
- Add `supabase/rollback/<same name>.sql` that returns the database to the state before. `check-rollbacks` compares a
  fingerprint of functions, grants, tables, columns, constraints, indexes, policies, triggers and jobs.
- To change a function, copy its **latest** definition (the last migration that creates or replaces it) and edit that.
- Public functions: `security definer`, `set search_path = ''`, check the caller (`private.require_team()` or
  `private.require_admin()`), and grant execute only to the roles that need it.
- Put internal helpers in the `private` schema.
- Errors that people read use `raise exception '...' using errcode = '22023'` with a plain sentence.
- After changing signatures, update `app/src/lib/database.types.ts`.

## App conventions

- Rules stay in the database. The app shows the database's messages.
- Pure logic goes in `app/src/lib` with a test next to it.
- Data comes from TanStack Query; add live refresh keys in `app/src/lib/live.ts` when a new table matters to a page.
- Dangerous actions ask first (`useConfirm`) and say what will happen.
- Wording follows [GLOSSARY.md](GLOSSARY.md); `npm run scan-text -w scripts` enforces it.
- Formatting is Prettier; linting is ESLint with no warnings allowed.

## Adding a feature: example order

1. A pgTAP file in `supabase/tests/database/` describing the rule (see `850_remove_domain_server_test.sql`).
2. The migration and its rollback.
3. A unit test and a function in `app/src/lib/`.
4. The screen change.
5. A Playwright scenario (see `e2e/tests/server-removal-scenarios.spec.ts`).
6. The in app guide in `app/src/help/`, and `npm run help:screenshots` if a picture changed.

## Extending the automation

Edit `n8n/WF*.json`, test the code nodes (`scripts/src/n8n-code.test.ts`), then export
([../n8n/README.md](../n8n/README.md)). New work for the automation should be a database function it calls, so the
rule stays testable.

## Debugging

| What | How |
|---|---|
| A database rule | `npm run db:test:scratch -w scripts -- 850_` runs files starting with that name |
| The message journey | `npm run mock` prints every message the automation would send |
| The local database | Studio at `http://127.0.0.1:55423` |
| Sign in emails | Mail catcher at `http://127.0.0.1:55424` |
| A browser test | `npm run e2e -- --keep --project=scenarios -g "title"`; traces and pictures in `e2e/results/` |
| App errors | The browser console; browser tests fail on any console error |

## Commit messages

One change per commit: a short summary line, then why, in plain words.
