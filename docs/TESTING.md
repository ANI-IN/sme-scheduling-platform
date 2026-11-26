# Testing

What is tested, how to run it and what it cannot tell you. The latest results are in
[TEST_REPORT.md](TEST_REPORT.md).

## Overview

| Layer | Command | Needs | Time |
|---|---|---|---|
| Format, lint, types, unit tests, build, production build check | `npm run check` | Node | about 2 minutes |
| Unit tests only | `npm test` | Node | under a minute |
| Database tests (pgTAP) | `npm run db:test` | `npm run db:start` | a few minutes |
| One database test file or prefix | `npm run db:test:scratch -w scripts -- 250_` | `npm run db:start` | seconds |
| Migrations on an empty database | `npm run check-migrations -w scripts` | `npm run db:start` | a minute |
| Rollbacks | `npm run check-rollbacks -w scripts` | `npm run db:start` | a few minutes |
| Mock journey and race checks | `npm run mock -- --race` | `npm run db:start` | a minute |
| Wording rules | `npm run scan-text -w scripts` | Node | seconds |
| Message journey rehearsal | `npm run integration:rehearse -w scripts` | Docker; on Windows `.npmrc` | a few minutes |
| Browser tests, everything | `npm run e2e` | Docker, `npx playwright install chromium` | about 3 hours |
| Browser tests, one project | `npm run e2e -- --project=scenarios` | same | under an hour |
| Speed at scale | `npm run e2e:scale` | same | some minutes |

## What each layer proves

- **Database tests** check every rule, permission and message: who is asked, what is blocked, what is sent, who may do
  what. Each file runs inside a transaction on a throwaway database and rolls back.
- **Unit tests** check the app's pure logic (dates and zones, filters, wording, forms) and run the n8n code nodes.
- **Browser tests** use a separate stack on ports 5552x with the app on 5174, never your local database. Projects:
  page tests at desktop, laptop, tablet and phone in light and dark; `crawl-desktop` and `crawl-mobile`, which press
  every enabled control; `scenarios`, the user journeys; `scale` (only with `e2e:scale`). A console error, a failed
  request, a serious accessibility problem, sideways scrolling, cut off controls or a dash on screen fails a test.

## Expected output

- `npm run check` ends with `Production build is clean`.
- `npm run db:test` ends with `All files passed.`
- `npm run check-rollbacks -w scripts` ends with `Every rollback undoes its migration exactly`.
- Playwright prints the number passed; failures keep a screenshot and a trace in `e2e/results/`.

## Continuous integration

`.github/workflows/ci.yml` runs the quick checks and database tests on every push to `main` and every pull request.
The browser tests run only when started by hand (**Actions, Checks, Run workflow**, tick the box), to save minutes.

## Limits

- Nothing talks to the real Discord, Gmail, Google Drive, Google sign in or n8n. Those are checked by hand after a
  deployment ([DEPLOYMENT.md](DEPLOYMENT.md#live-checks)).
- Some browser scenarios depend on dates in the test data; a heavily loaded computer can cause time limit failures, so
  run the full suite on an idle machine.
- The backup script is tested for refusing and locking, not against a hosted database.
