# Changelog

Meaningful changes, newest first. Dates are 2026. Tags in Git mark releases.

## Repository publication, 26 November

- Personal and company details in all earlier commits replaced with invented values; internal reports, planning
  papers and review screenshots left out. Commit authors, dates and messages kept.
- Removed unused code: the retired hosted test journey, one off helper scripts and four unused functions.
- Account values moved out of the code: `SUPABASE_PROJECT_REF` for backup and clock, `n8n/instance.json` for the
  workflow export. The backup folder is in the home folder.
- New documentation and help pictures made from invented data.
- Continuous integration runs quick and database checks on push, browser tests on request.

## release-get-started, 26 November

- Get started counts only what is in use; its domain steps follow the chosen domain.

## release-server-removal, 26 November

- Admins can remove a domain's Discord server (not on a Live domain); archived domains are hidden and never count as
  using a server; clear them all at once.

## release-batch-6, 26 November

- Replies go to the right instructor; status changes ask first; drafts stay with their domain; "send again" is safer;
  bounces handled once; automatic replies raise no task; clearer messages and better contrast.

## release-batch-5, 25 November

- Stricter admin rules during the beta; safer delivery with waits between retries; hourly safety run; deletes need an
  admin; fewer database write rights; one backup at a time.

## release-batch-1 to release-batch-4, 23 to 25 November

- Messages at any hour with optional quiet hours; a Draft domain sends nothing; Check needed for unreported sends; the
  Schedule board legend and help panel; fixes for two serious access and delivery problems.

## Release 3 (tags release3-baseline, release3-m0), 22 to 23 November

- Database clock, admins and beta list, Discord server approval, schedule checks, standard schedules, breaks, proposed
  times, shared classes, cohort merges and the new Schedule board.

## Releases 1 and 2, before 22 November

- The first scheduling engine and app, access control and audit, time zones and Discord, archive and delete.
