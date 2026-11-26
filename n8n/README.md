# n8n workflows

Six workflows connect the database to Discord, Gmail and Google Drive. They hold **no business rules**: they call
database functions, send the messages those functions queue, report the results, serve the answer pages the database
renders and pass typed replies in. Settings and credentials: [../docs/CONFIGURATION.md](../docs/CONFIGURATION.md).

## The workflows

| File | Runs | What it does | Calls |
|---|---|---|---|
| `WF1-hourly-engine.json` | Every hour (leave unpublished while the database clock is on) | The automatic check | `engine_tick_all` |
| `WF2-response-handler.json` | Webhook `GET` and `POST` `respond` | Answer pages: showing records nothing; pressing records the answer | `response_page`, `submit_response_page` |
| `WF3-daily-jobs.json` | Daily 09:00 (Asia/Kolkata) | Daily system summary; nightly backup to Drive, newest 30 kept | `daily_jobs`, `export_snapshot` |
| `WF4-action-runner.json` | Webhook `POST` `sme-poke` and every hour | The only sender: delivers messages, runs app actions and Discord checks, reads replies | `next_actions`, `complete_action`, `claim_outbound_messages`, `report_message_result`, `next_discord_lookups`, `record_discord_result`, `discord_watchlist`, `set_discord_cursor`, `engine_tick_all`, `log_system_error` |
| `WF5-error-handler.json` | When another workflow fails | Records the error and alerts the admin channel, even if the database is down | `log_system_error` |
| `WF6-discord-checks.json` | Every minute (leave unpublished; WF4 does these checks) | Spare for Discord checks | `next_discord_lookups`, `record_discord_result` |

## The database clock and pokes

A **poke** is a `POST` to WF4's webhook with the header `x-poke-key`. It carries no data and only means "there is work".

| Job in the database | When | What |
|---|---|---|
| `sme-engine-hourly` | Minute 30 of every hour | Runs the automatic check inside the database |
| `sme-clock` | Every 2 minutes | Pokes WF4 only when there is work (waiting messages, app actions, Discord checks, or replies to read) |

New messages and Discord checks also poke WF4 within seconds. Reply reading slows as this month's counted runs grow:

| Runs this month | Replies are read, while a conversation is open |
|---|---|
| Under 5,000 | About every 10 minutes |
| 5,000 to 6,499 | About every 30 minutes |
| 6,500 to 7,999 | About every hour |
| 8,000 and more | Only when WF4 runs for other work |

## Typed replies

- **Email:** only mail to the `+scheduling` reply address, and bounces of emails the app sent. Handled mail gets the
  label **SME Scheduling/Processed**; nothing is marked read. A bounce counts only in the thread of an email sent to
  that address.
- **Discord:** only messages the instructor writes in their own channel, in an approved server. Needs the Message
  Content Intent.

## Delivery

WF4 claims up to 25 messages a run and reports each one. Permanent errors (most 4xx answers) fail at once; temporary
errors are tried up to 4 times in all, after about 1, 5 and 15 minutes (or as long as Discord asks). An expired login
makes messages wait and raises one alert. A message taken and never reported within 15 minutes becomes **Check
needed**, and a person chooses whether to send it again.

## Setting up

1. Create the five credentials listed in
   [../docs/CONFIGURATION.md](../docs/CONFIGURATION.md#n8n-credentials) in your n8n.
2. Copy `n8n/instance.example.json` to `n8n/instance.json` and fill in your values.
3. Build your workflows:

   ```bash
   npm run n8n-export -w scripts
   ```

4. Import the files in `n8n/generated/`, **WF5 first** (the others use it as their error workflow).
5. In WF1 to WF4, **Settings, Error workflow**, choose WF5. Choose credentials on any node that shows a warning.
6. Publish WF5 and WF4, then WF2 and WF3. Leave WF1 and WF6 unpublished while the database clock is on.
7. Switch the clock on ([../docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md#4-automation)).

Every workflow starts with a **Config** node that the export fills in; nothing needs typing there.

## Changing a workflow

1. Edit the base file `n8n/WF*.json` (never the generated files).
2. `npm run test -w scripts` runs the code nodes' tests.
3. Export, then in n8n open the workflow, remove its nodes and use **Import from File** with the generated file, so its
   history is kept.
4. Check credentials, the error workflow and which triggers are off; publish; run it once and check the execution.

To go back, restore the previous version from the workflow's history and publish it.

## Webhooks

| Workflow | Method and path | Protection |
|---|---|---|
| WF2 | `GET` and `POST` `/webhook/<pathPrefix>respond` | Random link tokens; link preview bots are ignored |
| WF4 | `POST` `/webhook/<pathPrefix>sme-poke` | Header `x-poke-key` |

The WF2 address goes into `RESPONSE_BASE_URL` (then `npm run configure:production -w scripts`); the WF4 address into
`npm run clock -w scripts -- on <address>`. The `/webhook-test/` addresses work only while n8n is listening for a test.

## Testing without accounts

With the local database running, `npm run mock -- --race` plays a whole class timeline, prints every message n8n would
send, answers through the same functions as WF2, and presses one Yes twice at once to show only one booking is made.
Troubleshooting: [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md).
