# Test report

The results of the last full verification, then every test scenario. How to run them: [TESTING.md](TESTING.md).

## Results

RESULTS

## Every scenario

<!-- scenarios:start -->

Made by `npm run test-list -w scripts` from the test files: 1753 database checks, 120 screen scenarios and 218 unit tests.

### Database tests (pgTAP)

<details><summary><code>010_rules_test.sql</code>: 44 checks</summary>

1. first booking for the shared instructor is accepted
2. overlapping booking in ANOTHER domain is rejected (exclusion constraint)
3. a different instructor can take the overlapping class
4. a class on the Tuesday between Sunday and Thursday does not clash
5. releasing a booking deactivates its slots
6. after release the instructor can be booked at that time again
7. a module week cannot have two active bookings
8. a second open outreach request for the same module week is rejected
9. once the first request is closed, the next instructor can be asked
10. a time-change request can be open alongside
11. duplicate message key is rejected
12. different key is accepted
13. duplicate primary email (any case) rejected with the existing name
14. duplicate Discord ID rejected with the existing name
15. a primary email equal to another instructor's extra email is rejected
16. an extra email equal to another instructor's primary email is rejected
17. primary email is mirrored into instructor_email
18. changing Discord ID removes the Verified badge
19. a channel link from a different Discord server is rejected
20. channel ID is extracted from the link
21. duplicate module week (module + week + cohort) rejected
22. Sun Jan 31 2027 9:00 AM PST = 17:00 UTC
23. Sun Mar 14 2027 9:00 AM PDT = 16:00 UTC (first PDT Sunday)
24. Sun Nov 7 2027 9:00 AM PST = 17:00 UTC (back to PST)
25. PDT label in summer
26. PST label the Sunday before
27. a class generated on the first PDT Sunday still starts at 9:00 PT
28. duration is 4 hours across the DST week
29. setup changes are logged with after values
30. edits are logged with before → after
31. history cannot be updated (even by the owner)
32. history cannot be deleted
33. a save based on an old version is rejected ("This changed: reload")
34. out-of-range setting rejected
35. readiness must be ≥ outreach + 5
36. valid setting accepted
37. domain value overrides the default
38. anonymous API calls cannot read instructors
39. a non-company account sees no data
40. a non-company account cannot write
41. a company account can read
42. a company account can edit setup data
43. a company account cannot edit history
44. bookings cannot be written directly through the API (only through database functions)

</details>

<details><summary><code>020_outreach_test.sql</code>: 46 checks</summary>

1. before 45 days nothing happens
2. readiness check passes at 45 days → Ready
3. no outreach before 30 days
4. outreach starts at 30 days
5. the primary (rank 1) is asked first
6. M1 queued on Discord and email together
7. M1 is ready to send (inside allowed hours)
8. owner tagged: outreach started (T1)
9. more than 10 days out: reminder after 24h
10. more than 10 days out: move on after 48h
11. M1 shows the class in PT with PST label
12. Discord message @mentions the instructor
13. three link buttons: Yes / No / Propose another time
14. repeat runs never duplicate messages
15. still exactly one request
16. opening the link shows a confirm page with the name
17. opening the link (GET) records nothing
18. reminder after 24h
19. M2 reminder queued on both channels
20. request closes after 48h
21. polite close (M3) sent
22. the next instructor is asked
23. more than 10 days out: no immediate T3 (owner sees it in the digest)
24. a late Yes after the request closed changes nothing
25. late Yes creates an attention item for ops
26. No is recorded
27. after a No the next instructor is asked immediately
28. never more than one open request
29. Yes confirms automatically
30. module week Confirmed
31. booking created for the instructor who said yes
32. booking covers both classes of the module week
33. confirmation (M4) sent on both channels
34. confirmation says how to get help (it no longer lists the materials, decision 268)
35. owner tagged on confirmation in the instructor's channel, plus their own copy (T2)
36. checklist created: 3 default items × 2 classes
37. second Yes click shows "Already recorded"
38. a No after the Yes changes nothing
39. still exactly one booking
40. used link shows Already recorded
41. no further outreach after confirmation
42. nobody else was messaged (no "sorry" messages)
43. claimed messages are marked Sending
44. a second claim gets nothing (no double send)
45. n8n reports a send
46. a failure is retried

</details>

<details><summary><code>030_outreach_rules_test.sql</code>: 57 checks</summary>

1. everyone declines → Needs instructor
2. urgent attention item (ranking exhausted)
3. T4 posted immediately in the alert channel, tagging owner + ops
4. T4 tags the module owner and ops contact
5. urgent items repeat every 4h until acknowledged (to owner + ops)
6. escalation after 8h, posted in the alert channel
7. I'm on it pauses repeats
8. assign manually works with the same booking function
9. reminders stop when resolved
10. manual mode asks the first ticked instructor (custom order)
11. then the next ticked instructor, one at a time
12. end of manual list with "Stop" → stop and alert
13. the ranking is not used
14. end of manual list with "Continue" → continues with the ranking
15. switching mode with a request open asks "keep waiting or withdraw?"
16. keep: the open request stays
17. withdraw: the open request is withdrawn and the manual list starts
18. the withdrawn instructor is told politely (M12)
19. still only one open request
20. skip to next asks the next in line (skipped instructors are not re-asked)
21. an instructor teaching in another domain at that time is skipped
22. skip reason logged ("Teaching <domain> at this time")
23. Yes that now clashes with another domain is not booked
24. the instructor sees an explanation
25. the next instructor is asked
26. ops notified
27. unavailable instructor is skipped for module weeks in that range
28. preview shows the reason
29. deactivating the instructor being asked withdraws the request and asks the next
30. deactivating someone with bookings asks keep or release
31. keep: the booking stays
32. release: the booking is released
33. module week marked At risk
34. impact preview counts upcoming unconfirmed weeks
35. impact preview shows who would be next
36. preview did not save anything
37. a ranking change never touches the request already sent
38. "who will be asked next" follows the new order
39. the next person asked follows the new order
40. undo restores the previous ranking
41. undo is logged
42. a change can only be undone once
43. messages in quiet hours wait
44. they are released at 8:00 AM PT
45. n8n cannot claim them early
46. released at 8 AM PT
47. kill switch on: nobody is asked
48. kill switch off: outreach resumes at the next run
49. test mode: email goes to the test inbox
50. test mode: Discord goes to the test channel
51. test mode: message prefixed with the real recipient
52. test mode: real instructors are never @mentioned
53. readiness fails without an owner
54. no owner → routed to the domain lead
55. still failing at 35 days → escalation
56. outreach is blocked while readiness fails
57. once fixed, outreach starts at the next run

</details>

<details><summary><code>040_checkins_changes_test.sql</code>: 63 checks</summary>

1. owner check-in (T11) at 14 days
2. owner check-in lists the week with status and All good / Need help links
3. optional 14-day instructor check-in is off by default
4. owner can answer All good
5. 10-day check-in (M6) on both channels
6. buttons: All set / Need help / Can't make it
7. no reply → one reminder after 24h (M9)
8. still no reply → attention item (normal for the 10-day check-in)
9. booking kept
10. 2-day (final) check-in (M7)
11. final check-in shows the class day and time in PT
12. All set is recorded
13. nothing else happens
14. second tap: Already recorded
15. module week completed after the last class
16. booking completed
17. no reply to the last check-in → urgent attention item
18. booking kept by default
19. Need help shows the help form at once (no materials, decision 284)
20. help form submitted; confirmation page shows who will reply and by when
21. check-in answered with Need help
22. booking stays
23. acknowledgement (M13) via the chosen channel
24. Can't make it asks "are you sure?" first
25. cancellation recorded
26. booking released
27. instructor gets M10
28. 15 days before: normal alert
29. owner and ops alerted (T5)
30. outreach restarts, skipping the instructor who cancelled
31. long-band windows (48h)
32. 7 days before: urgent
33. 3 to 10 days: move on after 24h
34. 3 to 10 days: reminder after 12h would be 10 PM PT (quiet hours) → moved to 8:00 AM PT
35. under 10 days: owner tagged on each move (T3)
36. At risk
37. under 3 days: move on after 6h
38. under 3 days: remind after 3h
39. urgent item so ops can phone people too
40. used link
41. time change bumps the time version
42. the instructor being asked gets an updated message (M5) instead of a new request
43. no new request
44. Yes still works with the new time
45. booked at the new time (10:00 AM PST)
46. confirmed instructor gets a time-change request
47. M5 on both channels
48. Still works keeps the booking
49. booking confirmed for the new time
50. Doesn't work releases the booking
51. and restarts outreach
52. no reply → attention item
53. booking kept
54. module week cancelled
55. booking cancelled
56. instructor told (M11)
57. old links explain the class is no longer scheduled
58. not yet confirmed: the open request is closed with M12
59. first PDT Sunday shows 9:00 AM PDT
60. review shows 6:00 PM PDT
61. the missed reminder is sent once after the outage
62. and never twice
63. still one request

</details>

<details><summary><code>050_help_reminders_test.sql</code>: 40 checks</summary>

1. help request created from the confirmation's Need help button
2. class materials → routed to the module owner
3. no rush and class > 7 days away → 24h target
4. instructor gets the acknowledgement (M13)
5. owner tagged right away (T7)
6. confirmation shows who replies and by when (PT)
7. a second request within 1 hour merges into the first
8. categories merged
9. reminder to the assignee at half the target time
10. escalation to the alert channel when the target passes
11. reply → waiting on instructor
12. reply sent to the instructor (M14)
13. first response recorded
14. an instructor follow-up re-opens the help request
15. follow-up attached to it
16. reading the same email twice does nothing
17. convert to cancellation
18. starts the cancellation flow (booking released)
19. and outreach restarts
20. Zoom / calendar → routed to ops
21. class less than 2 days away → 2h target, urgent from the start
22. help still open 2 days before → At risk (help pending)
23. resolving the help request closes its attention item
24. no checklist nudge before 3 days
25. checklist nudge 3 days after confirmation
26. not done 7 days before → urgent
27. and escalated
28. all items done → resolved automatically
29. schedule running low (< 6 weeks planned ahead) → attention item
30. email bounce → attention item
31. instructor flagged until fixed
32. after retries the message is marked Failed
33. Discord failure flagged on the instructor
34. failure becomes an attention item
35. typed reply → attention item
36. nothing changes automatically
37. daily digest sent to team members with open items
38. digest is the first reminder (R1) for normal items
39. only one digest per person per day
40. daily heartbeat (T15) to the admin channel

</details>

<details><summary><code>060_app_actions_test.sql</code>: 24 checks</summary>

1. anon cannot run the engine
2. anon cannot record answers
3. the app cannot record instructor answers (n8n only)
4. the app cannot claim the outbox
5. the app cannot render instructor pages
6. the app can call action functions
7. a non-company account is refused inside the function
8. a company account can act
9. the action is recorded with the member who did it (AUTH-3)
10. kill switch on: n8n cannot claim instructor messages
11. they are held, not lost
12. kill switch off: they go out
13. Reply from Needs Attention is sent to the instructor (M14)
14. and the item is acknowledged
15. resend creates a new outbox row (new unique key)
16. generator: Mar 7 live class at 9:00 AM PST
17. generator: Mar 14 (first PDT Sunday) still 9:00 AM
18. stored 16:00 UTC
19. planned weeks are created
20. planning the same weeks again is refused with a message
21. shifting onto a week the module already has is refused
22. shift this + later: the PST week moved into PDT and still starts at 9:00 AM PT
23. both weeks moved by one week, no duplicates
24. undo of a setting restores the default

</details>

<details><summary><code>070_review_fixes_test.sql</code>: 22 checks</summary>

1. #1 paused test domain: confirmation still goes to the test inbox
2. #1 and is marked as a test message
3. #2 a No while the kill switch is on leaves the week Ready (not stuck Asking)
4. #2 the next run asks the next instructor
5. #3 release without restart: nobody is asked at the next run
6. #3 the week is paused until ops resumes it
7. #4 shift: one time-change request
8. #4 shift: one M5 per channel
9. #4 the message shows the final times only
10. #4 time version bumped once
11. #5 two owner check-ins on the same day are both queued
12. #6 a team member cannot run the engine with a made-up "now"
13. #6 engine_tick is not granted to the app
14. #7 flagged while help is open
15. #7 flag cleared once the help request is resolved
16. #8 typed reply with no open item is routed to ops
17. #9 the deadline is never after the (new) first class
18. #9 under 3 days now: move on 6h after the change
19. #10 no time-change request while paused
20. #10 created at the next allowed run
21. #11 cannot resend a message that is still waiting to go out
22. #12 the owner's digest lists the decline

</details>

<details><summary><code>080_release_model_test.sql</code>: 45 checks</summary>

1. a class week without a cohort name joins the Main cohort
2. every class week belongs to a cohort
3. two cohorts of the same module run in the same week
4. instructor 1 is confirmed for the main cohort
5. the same instructor can never be confirmed for overlapping classes in another cohort
6. and the automation skips them for the overlapping cohort
7. another instructor teaches the other cohort at the same time
8. the same instructor teaches two cohorts when the times do not overlap
9. a weekday cohort uses its own pattern: Monday and Wednesday
10. the main cohort keeps the module default: Sunday and Thursday
11. a mixed cohort: a weekend class and a weekday class in one class week
12. planning shows why a module without class times cannot be planned
13. and saving it is blocked
14. a confirmed class moved from Sunday to Wednesday asks the instructor to confirm the new time
15. the class week now starts on its first class (Wednesday)
16. a one off class can be its own class week in a cohort
17. a class added to a confirmed class week is booked for the same instructor
18. a class on a holiday needs the warning to be accepted
19. a class before 6 AM Pacific is a warning
20. accepting the warning saves the class
21. the reason for accepting a warning goes into Activity history
22. overlapping classes in the same cohort are a warning, not a block
23. turning "same instructor" off makes each class its own class week
24. with one class each
25. each class gets its own request
26. they can only be merged back while nobody is being asked
27. planning a module with "same instructor" off creates one class week per class
28. a cohort override wins for its class weeks
29. and the app can show where the value comes from
30. the automation uses the cohort value
31. settings cannot be set for one module
32. or for one class week
33. then the domain value
34. then the default
35. the first person saves
36. the second person, who opened the old version, is told to reload
37. an instructor order must start with a Primary instructor
38. a cohort can have its own instructor order
39. other cohorts keep the module order
40. a cohort can have its own operations team for a module
41. otherwise the domain default operations team is used
42. escalation contacts replace domain leads
43. Team shows where each person helps
44. one person can test as several test instructors with one Discord account
45. real instructors keep a unique Discord user ID

</details>

<details><summary><code>090_access_test.sql</code>: 26 checks</summary>

1. a company Google account may sign in
2. an account from another domain is refused
3. a refused sign in is recorded in Activity history
4. in Production the development email link cannot be used
5. in Production a Google account without the company hosted domain is refused
6. in Production a company Google Workspace account is accepted
7. in Production an email link session gets no access, even with a company address
8. a session that only writes the company domain into its own profile gets no access (SEC-1)
9. and a company Google session does
10. in Production a Google user who signed in by email link (amr otp) gets no access
11. the first sign in creates the team member from the Google name
12. and asks once for their Discord username
13. a Discord username has only letters, numbers, dots or underscores
14. once added, the question is not asked again
15. sign ins are recorded
16. choosing "Later" also stops the question
17. removing access is recorded with the reason
18. nobody can remove their own access
19. removing access ends their sessions everywhere (SEC-2)
20. and ending the sessions worked (nothing was only logged)
21. a removed person cannot use the app
22. and sees no data
23. and cannot sign up again
24. and is no longer tagged or reminded
25. only the setup script can change the environment and the allowed domain
26. without an allowed domain nobody can sign in

</details>

<details><summary><code>100_audit_test.sql</code>: 19 checks</summary>

1. the reason for an override is recorded
2. with the setting's readable name
3. and the cohort it applies to
4. and its domain
5. class week actions carry the cohort
6. and who did it
7. a change made directly in the database is labelled "Database admin", not "System"
8. a removed instructor is still named in Activity history
9. creating a domain cannot be undone
10. creating a module cannot be undone
11. editing a module can be undone
12. manual and automatic actions are not offered for undo
13. and the database refuses to undo the creation of a module
14. going live is recorded
15. pausing all messages is recorded
16. downloads are recorded with the number of rows
17. repeated app errors are counted, not stored again
18. signed out visitors cannot write to the error log
19. the error log is written only through the function

</details>

<details><summary><code>110_pages_test.sql</code>: 27 checks</summary>

1. a dash starts a new sentence
2. a dash between times means "to"
3. and between numbers
4. team messages are stored without dashes
5. confirm pages have no dashes
6. default instructor messages have no dashes
7. a request without the classes and reply by date cannot be saved
8. unknown details are refused
9. a saved template is used for the domain
10. the templates page shows it as changed
11. the live preview fills in sample details
12. Reset to default brings back the default (its greeting is added by the message, decision 267)
13. a domain can have its own holiday
14. other domains do not see it
15. an extra task can be added to one class
16. and removed again
17. Start asking now asks the first instructor straight away
18. but not while someone is already being asked
19. one value at a time still checks the rules between settings
20. saving several values together checks the rules once all are in place
21. and still refuses values that break them
22. a new domain can copy settings from another domain
23. a domain that is fully set up has every checklist item done
24. a new domain shows what is missing
25. the modules overview counts class times
26. passed
27. and leaves nothing behind

</details>

<details><summary><code>120_environments_test.sql</code>: 23 checks</summary>

1. Production never messages a test instructor
2. and says why
3. a blocked message is recorded in Activity history
4. real instructors are messaged as usual in Production
5. Sandbox does not email domains that are not allowed
6. Sandbox emails allowed domains
7. Sandbox never emails a real instructor, even at an allowed address
8. and says why
9. team members at an allowed address still get email in Sandbox
10. a real instructor's copy in a domain being tested goes to the testing email
11. Sandbox posts in an allowed Discord server
12. Sandbox never posts to a channel the bot has not listed (no guessing the server, SEC-5)
13. and nowhere else (the server's approval removed)
14. messages already allowed are not changed
15. the check runs again before a message is sent
16. resetting needs RESET typed
17. a reset says the Sandbox was emptied
18. a reset leaves no domains, cohorts, modules or classes: no practice data is loaded
19. and no instructors, test instructors or holidays
20. Activity history is kept, never deleted: every row from before the reset is still there
21. real team members keep their access after a reset
22. placeholder team members are removed
23. Production data can never be reset

</details>

<details><summary><code>130_e2e_fixes_test.sql</code>: 5 checks</summary>

1. a time range uses "to"
2. also in summer time
3. unavailable dates use "to"
4. the first call creates the team member
5. a second call at the same moment does not fail

</details>

<details><summary><code>140_r2_reminders_test.sql</code>: 30 checks</summary>

1. 1. by default a reminder is planned while we wait
2. 1. and sent after 24 hours on Discord and email
3. 2. off: no reminder is planned
4. 2. and none is sent
5. 2. the next instructor is still asked after 48 hours
6. 3. 0 hours means no reminder
7. 3. moving on is not affected
8. 4. a cohort can switch a reminder back on for its own classes
9. 5. switching off part way stops a reminder that was already planned
10. 5. and the next instructor is still asked
11. 6. by default the instructor is reminded 10 days before
12. 7. confirming still works
13. 7. off: no reminders before class
14. 8. an empty list means no reminders before class
15. 8. a list with only 2 sends only the last reminder
16. 9. by default the owners are asked 14 days before
17. 9. 0 days means the owners are not asked
18. 10. off: owners are not asked
19. 10. off: no class task reminders
20. 10. the class tasks themselves are still there
21. 11. by default the operations team is reminded about class tasks after 3 days
22. 11. 0 days means no class task reminder
23. 12. 0 hours: no repeat reminder about an open task
24. 12. 0 hours: no escalation
25. 13. daily summary off: no summary for tasks of that domain
26. 13. switched back on: the summary is sent
27. 14. with every reminder off, instructors are still asked in order
28. 14. nobody left to ask is still detected
29. 14. and the urgent alert is still raised
30. 14. and the team is still told at once

</details>

<details><summary><code>150_r2_time_zones_test.sql</code>: 29 checks</summary>

1. 1. Sun Mar 7, 9:00 AM PST is 17:00 UTC
2. 2. Sun Mar 14, 9:00 AM PDT is 16:00 UTC: the class stays at 9:00 AM after the clocks move forward
3. 3. Sun Oct 31, 9:00 AM PDT is 16:00 UTC
4. 4. Sun Nov 7, 9:00 AM PST is 17:00 UTC: the class stays at 9:00 AM after the clocks move back
5. 5. India: Sun Mar 14, 9:00 AM IST is 03:30 UTC
6. 6. India: Sun Nov 7, 9:00 AM IST is also 03:30 UTC
7. 7. 2:30 AM on Mar 14, 2027 does not exist: it is refused with a clear message
8. 7. the same time in India is fine
9. 8. 1:30 AM on Nov 7, 2027 happens twice: the app must ask which one
10. 8. two choices are offered
11. 8. the first is PDT, the second PST
12. 9. the first 1:30 AM (PDT) is 08:30 UTC
13. 9. the second 1:30 AM (PST) is 09:30 UTC
14. 10. a US winter class shows PST
15. 10. a US summer class shows PDT
16. 10. an India class shows IST
17. 10. the team sees both local times, even when the dates differ
18. 11. a new cohort gets the region chosen for it
19. 11. both cohorts are planned in the same week, each in its own time zone
20. 11. messages for the India class show IST
21. 11. the plan preview lists only real warnings (no empty ones)
22. 12. one class in a US cohort can be an India class
23. 12. and its time is read as India time
24. 13. moved to Mar 14 at 9:00 AM: now PDT (16:00 UTC)
25. 14. 11:00 PM India time is quiet for an India class: sent at 8:00 AM India time
26. 14. the same moment is 9:30 AM Pacific, fine for a US class
27. 15. a US class on a US holiday is warned about
28. 15. an India class on a US holiday is not
29. 15. an India class on an India holiday is warned about

</details>

<details><summary><code>160_r2_conflicts_test.sql</code>: 16 checks</summary>

1. 1. a second class at an overlapping time is refused, naming the other class, its cohort and both times
2. 2. the same instructor teaches two cohorts at different times
3. 3. a clash with a class in another domain is refused too
4. 4. a Sunday 9:00 AM IST class and a Saturday 7:30 PM PST class are the same moment: refused
5. 5. moving a class onto another class of the same instructor is blocked with a clear message
6. 5. and the class keeps its time
7. 6. adding a class at a busy time to a confirmed class week is blocked
8. 7. before the clock change the two classes do not overlap
9. 7. after the clock change the same local times overlap, and the clash is found
10. 8. in the instructor order, an instructor with a clash is skipped with the reason
11. 9. once the other class is cancelled, the time is free
12. 10. once released, the instructor can take the other class
13. 11. a Yes for a clashing class is not booked
14. 11. the request is closed as a clash
15. 11. and no second booking is made
16. 12. even a direct write can never give an instructor two classes at the same time

</details>

<details><summary><code>170_r2_discord_test.sql</code>: 37 checks</summary>

1. 1. Refresh asks the automation for the bot's servers
2. 1. the message runner (WF4) leaves Discord checks to the Discord workflow (WF6)
3. 1. the servers are saved for people to choose from
4. 2. a server the bot is not in cannot be chosen
5. 2. choosing a server starts a check
6. 3. a server the bot can use is Ready
7. 3. text channels are listed with their category (voice channels are left out)
8. 3. without Server Members Intent the domain shows exactly what to turn on
9. 3. the check is in Activity history
10. 4. a server the bot cannot open asks for the invite link
11. 5. the username is saved in lowercase without @ and a check starts
12. 5. the automation is asked to find the person
13. 5. a username with spaces or symbols is refused with an example
14. 6. the servers of the instructor's domains are searched first, then the others
15. 7. only the exact username counts: the right Discord account is found
16. 7. finding the account is in Activity history
17. 8. nobody with that username: Not found
18. 8. the problem names the username and the server
19. 9. when the bot may not search members, the fix is named
20. 10. an account already used by another instructor is refused
21. 10. and the other person is named
22. 11. a new username forgets the old account and checks again
23. 11. pressing Check Discord again does not queue the same check twice
24. 11. removing the username clears the status
25. 12. a channel in another server the bot is in can be chosen
26. 12. a channel that is not in the list cannot be chosen
27. 12. the chosen channel is saved with its name
28. 12. choosing a channel is in Activity history
29. 13. a request goes to the instructor's channel in that domain
30. 14. a team member without Discord is asked once for a username
31. 14. after giving a username the question stops
32. 14. and the bot is asked to find them
33. 15. the app cannot take the automation's Discord work
34. 15. nor write Discord answers
35. 16. in Sandbox a direct message to a real instructor is blocked
36. 16. a post tagging a real instructor is blocked too (Sandbox never contacts real instructors)
37. 16. a team post in a channel of an allowed server is fine

</details>

<details><summary><code>180_r2_notifications_test.sql</code>: 31 checks</summary>

1. 1. a request goes to the instructor's channel and by email, not by direct message
2. 1. the instructor is tagged in the post
3. 1. with Yes and No buttons
4. 2. without a channel in this domain the request goes by direct message and email
5. 3. without Discord the request goes by email only
6. 4. a channel belongs to one domain: in another domain the instructor gets a direct message
7. 5. the confirmation is posted in the instructor's channel
8. 5. tagging the instructor and the owner
9. 5. the team tags are in the text
10. 6. the instructor also gets the confirmation by direct message
11. 6. and by email
12. 7. no extra post in the alert channel: the team is tagged in the instructor's channel
13. 7. the owner gets a direct message
14. 7. the operations person without Discord gets an email instead
15. 8. one copy per person (no duplicates)
16. 8. queuing the confirmation again sends nothing twice
17. 9. without a channel: the confirmation goes by direct message and email (once each)
18. 9. and the team is tagged in the alert channel instead
19. 10. a reminder before class goes to the channel and by email
20. 10. a help reply goes to the channel and by email
21. 11. the released instructor gets a thank you and release note in their own channel
22. 11. the note thanks them
23. 11. the new confirmation goes to the new instructor's channel
24. 12. a refused direct message creates a task that says what to do
25. 12. and the operations team gets an email (Discord may be what is broken)
26. 12. one message per operations person about the failure, never two
27. 12. when that email fails too, it is only logged: no new task, so failures never go round in circles
28. 12. the failure is in Activity history under Discord
29. 13. a deleted channel: the task names it and says to choose a new one
30. 14. every Discord send is in Activity history with the channel
31. 15. in a testing domain, Discord copies go only to the testing channel, never by direct message

</details>

<details><summary><code>190_r2_workflow_gaps_test.sql</code>: 24 checks</summary>

1. manual 1. instructor 1 is being asked
2. manual 2. exactly one active booking after a manual assignment
3. manual 3. the booking is for the instructor chosen by the team
4. manual 4. the booking says it was made by hand
5. manual 5. the open request to instructor 1 is closed
6. manual 6. instructor 1 is told politely that the class is taken (M12)
7. manual 7. the note from the team is in Activity history
8. manual 8. a class week that already has an instructor cannot get a second one by hand
9. manual 9. an instructor who is not in use cannot be assigned
10. manual 10. and no booking is left behind
11. manual 11. a yes given outside the app is recorded as an offline confirmation
12. confirm 1. the booking records when it was confirmed
13. confirm 2. the booking holds one time slot per class
14. confirm 3. the checklist is created for a manual booking too
15. confirm 4. the class week is Confirmed
16. replace 1. the booking is released
17. replace 2. the booking says the team released it, and the reason is in Activity history
18. replace 3. no time slot is held for the released instructor
19. replace 4. the released instructor gets the thank you and release note
20. replace 5. the released instructor is not asked again for this week
21. replace 6. someone else is asked
22. replace 7. after the replacement there is still exactly one active booking
23. replace 8. the new instructor gets the confirmation
24. replace 9. releasing a class week without an instructor says there is nobody to release

</details>

<details><summary><code>200_r2_review_fixes_test.sql</code>: 41 checks</summary>

1. DIS-3 a temporary Discord error keeps the Discord account and the contact check
2. DIS-7 an answer for an old username is ignored and the new username is looked up
3. DIS-7 a check stuck for more than 10 minutes is handed out again
4. DIS-12 View Channels and Send Messages from the everyone role: the bot can post
5. DIS-12 a private channel that hides it from everyone: the bot cannot post
6. DIS-12 the bot's role allowed in a private channel (like the 1-1 category): the bot can post
7. DIS-12 a channel the bot cannot post in cannot be chosen
8. DIS-15 another instructor's channel cannot be chosen
9. DIS-6 without a channel in the domain the instructor gets a direct message, never an old channel
10. DIS-9 the confirmation by direct message does not list or tag the team
11. DIS-4 a team member without Discord gets the reminder by email
12. DIS-10 a team member whose direct message failed gets the same message by email
13. DIS-10 the task says what really reached them
14. DIS-1 without an alert channel nothing is posted; one task asks to choose a channel
15. DIS-13 a message stuck after three tries waits for a check, not sent again
16. DIS-5 a reply to someone who chose Discord but has none still goes by email
17. OUT-2 a request that never went out is withdrawn when someone else is assigned
18. OUT-2 and the instructor is not told "no longer needed" about a request they never saw
19. OUT-3 a confirmed week is not left paused
20. OUT-4 a cohort's quiet hours (until 10 AM) hold a 9:30 AM message
21. OUT-5 weekly reminders are switched off with the other reminders
22. OUT-6 a week that is over is closed even without an instructor
23. OUT-6 and its urgent task stops
24. OUT-7 the merged request becomes urgent
25. OUT-7 with an urgent reply target
26. OUT-8 help requests of a cancelled class week are closed
27. OUT-9 (check) 11:30 PM India time is inside team quiet hours
28. SCH-1 adding a class on top of another class of the same week is refused
29. SCH-1 moving a class on top of another class of the same week is refused
30. SCH-3 a class time with the same start and end is refused
31. SCH-3 a time outside 6 AM to 10 PM asks for confirmation first
32. SCH-2 every class of a booked week holds a slot for the instructor
33. SCH-4 moving dates onto the instructor's other class is refused instead of releasing them
34. SCH-6 (check) India times are labelled IST
35. SEC-2 the email of someone whose access was removed cannot be changed
36. SEC-2 and they cannot be deleted to get round it
37. SEC-3 no answer link secret is stored in any message
38. SEC-4 the answer link address cannot be changed from the app
39. SEC-5 a Discord message with both a channel and a person is blocked
40. SEC-6 data cannot be reset on a database that was never configured
41. SEC-6 a new database starts as Sandbox (Google sign in only), not Development

</details>

<details><summary><code>210_r2_review_fixes_2_test.sql</code>: 19 checks</summary>

1. started 1. instructor 1 confirms
2. started 2. their answer is taken (never used link)
3. started 3. the booking stays: nothing is released after the class started
4. started 4. nobody else is asked
5. started 5. the team gets an urgent task to handle it directly
6. manual 12. an instructor not checked yet can be assigned by hand
7. manual 13. a test instructor cannot be assigned in a Live domain
8. manual 14. an instructor who cannot teach those dates is refused, with the dates
9. manual 15. an instructor teaching at the same time is refused, with the other class named
10. manual 16. and no booking is left behind by any refusal
11. back to back classes (one ends as the next starts) can both be booked for one instructor
12. test instructors can all be found through one shared Discord username
13. and they share the one Discord account
14. a request for an India class shows its time in India time (IST)
15. with US Pacific time in brackets after it, never the other way round
16. SEC-3 a request waiting to be sent keeps placeholders, never the secrets
17. SEC-3 the automation takes the request to send
18. SEC-3 no placeholder is left in what it gets
19. SEC-3 every button it gets carries the real link of that request

</details>

<details><summary><code>220_r2_review_fixes_3_test.sql</code>: 19 checks</summary>

1. SCH-5 no planning lock is held before planning
2. SCH-5 planning holds the domain's planning lock until the plan is saved
3. SEC-11 another person's link placeholder never turns into the working link
4. SEC-15 a real link never goes into a test copy, even for the same instructor
5. SEC-15 (the copy is a test copy)
6. SEC-11 the instructor's own message still gets their own working links
7. SEC-12 instructor 1 confirms
8. SEC-12 the page after "All set" has no placeholder left
9. SEC-12 and its Need help button carries the instructor's own working link
10. DIS-13 a message the automation took but never answered for is not sent again
11. DIS-13 and it says to check whether it arrived
12. OUT-3 a class week with a confirmed instructor cannot be paused
13. OUT-3 a time change says no request was made while messages are paused
14. OUT-4 the request waits for the end of the cohort's quiet hours (11:00 AM Pacific)
15. OUT-4 a class week without that cohort setting is asked at 8:00 AM, as the domain says
16. a second contact check while the first is still on its way is refused
17. and only one contact check email exists
18. SEC-5 Sandbox never sends a direct message to an account that is not a team member's, even for a test instructor
19. SEC-5 a test instructor using the tester's own Discord account gets the direct message

</details>

<details><summary><code>230_core_archive_delete_test.sql</code>: 55 checks</summary>

1. setup: instructor 1 confirms the first week
2. setup: someone is being asked for the second week
3. week 1. a class week with a confirmed instructor asks for its name
4. week 2. the preview says the confirmed instructor is told, as for a cancellation
5. week 3. a class week nobody is confirmed for or asked about needs no typed name
6. week 4. a wrong name is refused
7. week 5. the name in any case deletes it
8. week 6. its booking and classes are gone, so nothing points at a missing class week
9. week 7. the instructor's cancellation notice is still queued to go out
10. week 8. Activity history keeps one entry with the module name and the old values
11. week 9. a cancelled class week can be restored
12. week 10. its classes are planned again
13. week 11. only a cancelled class week can be restored
14. instr 1. the preview lists their places in instructor orders
15. instr 2. deleting someone with linked data asks for their name
16. instr 3. the instructor is gone
17. instr 4. the instructor order closes up without a gap
18. instr 5. their channels and email addresses go with them
19. instr 6. Activity history keeps their name and details
20. instr 7. the preview says their confirmed classes are released
21. instr 8. their confirmed class week has nobody booked any more
22. instr 9. the message telling them stays, with its address, after they are deleted
23. module 1. archive sets the module to archived
24. module 2. its class weeks stop: they are paused
25. module 3. restore makes it active again
26. module 4. its class weeks start again
27. module 5. a week that was paused by hand before stays paused
28. module 6. a module with classes asks for its name
29. module 7. the module, its class weeks and its class times are gone
30. module 8. the other module of the domain is untouched
31. module 9. one history entry for the delete, not one per row
32. cohort 1. a cohort can be added and renamed
33. cohort 2. archive hides the cohort
34. cohort 3. restore brings it back
35. cohort 4. a cohort with its own class times asks for its name
36. cohort 5. the cohort and its class times are gone
37. team 1. someone whose access was removed cannot be deleted (they stay blocked)
38. team 2. the preview lists their roles
39. team 3. the person and their module roles are gone
40. discord 1. a server can be archived (hidden)
41. discord 2. deleting a server removes it and the instructor channels in it
42. discord 3. the domain no longer has a server chosen
43. domain 1. the hourly check skips an archived domain
44. domain 2. and runs again after it is restored
45. domain 3. the preview lists the modules and the confirmed instructors who are told
46. domain 4. a domain with modules is not deleted without its name
47. domain 5. the domain, its modules, cohorts and class weeks are gone
48. domain 6. the confirmed instructor is told, as for a cancellation
49. domain 7. the other domain is untouched
50. domain 8. Activity history keeps the domain and the names of its modules
51. domain 9. every older history entry is still there
52. undo 1. a permanent delete cannot be undone
53. undo 2. an edit can still be undone
54. undo 3. removing a row cannot be undone
55. undo 4. history still cannot be edited

</details>

<details><summary><code>240_core_discord_servers_test.sql</code>: 18 checks</summary>

1. many 1. all 16 servers the bot is in are listed
2. many 1b. a server waiting for approval is not checked
3. many 2. each server gets its own status, and the ones never checked are checked
4. many 3. one check is queued per server, not more
5. many 4. one run takes at most three server checks, to stay under Discord's limits
6. many 4b. each piece of work is one object with its action and its server, as the workflow reads it
7. many 5. the rest wait for the next runs
8. many 6. a server the bot can use is Ready on its own row
9. many 7. the time of the check is kept
10. many 8. a server the bot cannot read shows a problem
11. many 9. with the reason
12. many 10. results are kept for a day: only the server checked two days ago is checked again
13. many 11. Check again checks one server now
14. many 12. a server the bot is not in cannot be checked
15. many 13. an archived server is not checked automatically
16. many 14. an instructor channel can be in any server the bot is in, not only the domain's
17. many 15. their Discord account is looked for in the server of their channel first
18. many 16. one run takes at most ten username searches

</details>

<details><summary><code>250_core_empty_start_test.sql</code>: 27 checks</summary>

1. empty 1. after a reset there are no domains, instructors, modules or classes
2. empty 2. Get started lists the seven first steps in order
3. empty 3. on an empty app no step is done yet
4. empty 4. each step links to the page where it is done
5. empty 5. adding a domain ticks "Add a domain"
6. empty 6. choosing its server ticks "Choose its Discord server"
7. empty 7. a second person ticks "Add team members"
8. empty 8. an instructor ticks "Add instructors"
9. empty 9. a module in use ticks "Add modules"
10. empty 10. a module alone does not tick "Create a cohort"
11. empty 10b. adding a cohort ticks it
12. empty 11. planning a class ticks "Plan classes": the list is done and Home stops showing it
13. empty 12. an archived domain does not count as set up
14. chosen 1. the set up domain has every step
15. chosen 2. a new domain starts with its own steps unticked
16. chosen 3. with no domain named, any domain in use counts
17. archived 1. nothing of an archived domain counts for another
18. archived 2. nor when no domain is named
19. archived 3. an archived domain named itself ticks none of its steps
20. archived 4. every domain archived: only what is really done
21. people 1. a person without access and an archived domain team do not count
22. people 2. an archived instructor does not count
23. deleted 1. an admin deletes the set up domain
24. deleted 2. and the new one
25. deleted 3. every domain deleted: only what is really done
26. empty 13. someone who is not signed in cannot read the list
27. empty 14. no placeholder people or built in holidays are left

</details>

<details><summary><code>260_core_cohorts_regions_test.sql</code>: 12 checks</summary>

1. cohorts 1. three cohorts of one domain run at the same time
2. cohorts 2. each cohort keeps its own region
3. cohorts 3. the same module in the same week gives one class week per cohort
4. cohorts 4. a US class at 9:00 AM Pacific is 17:00 UTC
5. cohorts 5. an India class at 7:30 PM India time is 14:00 UTC
6. cohorts 6. every class carries the region of its cohort
7. cohorts 7. messages about the India class show India time
8. cohorts 8. the same instructor can be booked for a US and an India class that do not overlap
9. cohorts 9. the India cohort has its own instructor order
10. cohorts 10. archiving the India cohort pauses only its class week
11. cohorts 11. deleting one cohort leaves the other two
12. cohorts 12. and their classes

</details>

<details><summary><code>270_demo_messages_test.sql</code>: 12 checks</summary>

1. tags 1. the confirmation in the channel lists each Discord user once
2. tags 2. the person is tagged once in the text, not again in a team line
3. tags 3. any message keeps each mention once, in order
4. help 1. the confirmation says how to get help
5. help 2. no instructor message lists the materials any more
6. help 3. the answer pages show no materials
7. help 4. the setup check does not ask for materials
8. help 5. no message template uses materials any more
9. fail 1. the task title says what failed, in plain words
10. fail 2. the task says what still reached her and where to look, without the technical error
11. fail 3. the admin channel still gets the technical error
12. fail 4. Activity history keeps the technical error in its details

</details>

<details><summary><code>280_final_round_test.sql</code>: 8 checks</summary>

1. one 1. the class at risk task is marked done when nobody is left to ask
2. one 2. the class week has one open task
3. one 3. closing it is in Activity history
4. words 1. nobody left: "Assign someone manually or add instructors to the instructor order."
5. words 2. Activity history says "Nobody left to ask"
6. words 3. a class at risk says "We've started asking the next instructor."
7. setup 1. "Setup check passed" is logged once for the module, not once per class week
8. setup 2. both class weeks still pass the check

</details>

<details><summary><code>290_baseline_fixes_test.sql</code>: 9 checks</summary>

1. 1. the Need help page no longer offers materials
2. 2. it opens the help form at once, with a help line
3. 3. the help form is no longer hidden behind "I still need help"
4. 4. an instructor can still ask for materials with Need help
5. 5. the request has a reply by time
6. 6. a US class shows the reply by time in US Pacific time
7. 7. with the Pacific zone named
8. 8. an India class shows the reply by time in India time
9. 9. with IST named, not Pacific

</details>

<details><summary><code>300_database_clock_test.sql</code>: 24 checks</summary>

1. 1. the clock is off until an admin switches it on
2. 2. the 2 minute job does nothing while the clock is off
3. 3. the hourly job does nothing while the clock is off
4. 4. switching on needs the WF4 poke address
5. 5. switched on with the address
6. 6. switching the clock on is logged in Activity history
7. 7. no work: no reason to call n8n
8. 8. no work: the job returns without calling n8n
9. 9. a message waiting to be sent is work
10. 10. a queued app action is work
11. 11. a queued Discord check is work
12. 12. an open conversation whose replies were never read is work
13. 13. replies read 5 minutes ago: not yet
14. 14. replies read 11 minutes ago: read them again (every 10 minutes)
15. 15. above 5,000 runs this month, 11 minutes is not enough
16. 16. above 5,000 runs, replies are read every 30 minutes
17. 17. above 8,000 runs, no run only to read replies
18. 18. above 8,000 runs, messages still go out (and replies are read then)
19. 19. with work the job tries to call n8n
20. 20. without the poke key in Vault nothing is sent, and the reason is kept
21. 21. one alert in Activity history when the brakes start
22. 22. at most one call to n8n a minute
23. 23. a call made by the app or a test is not counted as an n8n run
24. 24. a WF4 run (its first call, next_actions) is counted

</details>

<details><summary><code>310_admins_sign_in_test.sql</code>: 41 checks</summary>

1. 1. the service can make the first admin
2. 2. giving admin rights is logged
3. 3. Ben is a normal user
4. 4. app links and alert channel: admins only
5. 5. Pause all messages: admins only
6. 6. removing access: admins only
7. 7. the admin channel test: admins only
8. 8. refreshing the Discord server list: admins only
9. 9. checking a Discord server: admins only
10. 10. settings for every domain: admins only
11. 11. archiving a Discord server: admins only
12. 12. Reset Sandbox data: admins only
13. 13. making an admin: admins only
14. 14. adding to the beta list: admins only
15. 15. removing from the beta list: admins only
16. 16. who may sign in: admins only
17. 17. a normal user still changes their domain's settings
18. 18. and checks an instructor's Discord username
19. 19. a normal user cannot read the beta list
20. 20. Ana is an admin
21. 21. only someone who has signed in can be an admin
22. 22. the last admin cannot remove themselves
23. 23. nor lose their access
24. 24. an admin makes another signed in person an admin
25. 25. every admin can do everything: Ben can now
26. 26. any admin can remove admin rights while another admin is left
27. 27. the last admin cannot be removed
28. 28. every admin change is in Activity history
29. 29. only company accounts can be on the beta list
30. 30. the beta list mode needs every admin on the list first
31. 31. an admin adds themselves
32. 32. and a colleague (case does not matter)
33. 33. the list keeps the address in lower case
34. 34. then switches sign in to the beta list
35. 35. which is logged
36. 36. a company account not on the list is refused
37. 37. a listed account gets in
38. 38. a new account not on the list cannot even be created
39. 39. an admin cannot be taken off the list
40. 40. a colleague can
41. 41. and is locked out at once, without waiting for the next sign in

</details>

<details><summary><code>320_beta_guard_test.sql</code>: 26 checks</summary>

1. 1. with the default settings nothing new is blocked
2. 2. only an admin changes who may receive messages
3. 3. an admin (here the setup command) switches the beta guard on
4. 4. the change is logged
5. 5. email to an outside address is blocked
6. 6. with the reason
7. 7. and logged in Activity history
8. 8. email to a company address goes out
9. 9. a real instructor is never contacted, even at a company address
10. 10. a test instructor is
11. 11. a direct message to a Discord account that is no signed in colleague's is blocked
12. 12. a direct message to a signed in colleague goes out
13. 13. a post that tags someone who is no signed in colleague is blocked
14. 14. a post that tags only signed in colleagues goes out
15. 15. a post to a real instructor is blocked whoever it tags
16. 16. a change between queueing and sending still stops the message
17. 17. in Production a test instructor may be asked while the beta setting is on
18. 18. and messaged
19. 19. with "Anyone", Production's own rule is back
20. 20. and test instructors are never messaged
21. 21. with Production's reason
22. 22. one email sent in the last 24 hours reaches a cap of 1
23. 23. at the cap, emails wait and Discord messages still go out
24. 24. the email is kept for later, not cancelled
25. 25. one task says the daily limit was reached
26. 26. the clock does not call n8n for emails that must wait

</details>

<details><summary><code>330_discord_server_approval_test.sql</code>: 27 checks</summary>

1. 1. a new server waits for approval
2. 2. a waiting server is not checked (its channels are not read)
3. 3. usernames are not searched in a waiting server
4. 4. a domain cannot choose a waiting server
5. 5. nothing is posted in a waiting server
6. 6. with the reason
7. 7. a normal user cannot approve a server
8. 8. an admin approves it for one domain
9. 9. the server is approved
10. 10. the approval is logged
11. 11. its channels are read right after the approval
12. 12. usernames are searched there now
13. 13. the approved domain can use it
14. 14. another domain cannot
15. 15. an instructor channel can be chosen there for the approved domain
16. 16. not for another domain
17. 17. posts for the approved domain go out
18. 18. posts for another domain are blocked
19. 19. a channel the bot never listed is blocked
20. 20. replies are read in a channel of an approved server
21. 21. an admin removes access at any time
22. 22. the domain that used it needs a fix
23. 23. with one task
24. 24. replies are no longer read there
25. 25. and nothing is posted
26. 26. the removal is logged
27. 27. a server can be refused

</details>

<details><summary><code>340_security_data_findings_test.sql</code>: 28 checks</summary>

1. 1. a signed in person cannot take messages to send
2. 2. nor anyone else who is not the automation
3. 3. app actions
4. 4. recording a reply as if it came in
5. 5. the daily jobs
6. 6. the automatic check for every domain
7. 7. the automation still can
8. 8. and takes app actions
9. 9. two replies in the same second are two messages
10. 10. each with its own key
11. 11. the domain's alert channel cannot be an instructor's channel
12. 12. nor its testing channel
13. 13. pausing a class week still works
14. 14. a confirmed class week is not paused
15. 15. after a release, the old instructor's Need help link has closed
16. 16. and no help request is filed against the replacement's booking
17. 17. the classes are over
18. 18. the unanswered help request still has its task, so someone answers it
19. 19. the secret part of a quoted answer link is removed from the stored reply
20. 20. and the secret itself is not kept
21. 21. a link closes when its classes are over
22. 22. every link expires after 90 days
23. 23. only the categories the page offers are kept
24. 24. sending the same help request again a moment later does not file another one
25. 25. a class listed twice in a plan is refused (SCH new 5)
26. 26. a US class and an India class that overlap in real time are refused (each in its own region)
27. 27. joining class weeks whose classes overlap into one is refused (SCH new 3)
28. 28. moving a US and India class week back across the clock change, where its classes would overlap, is refused (SCH new 4)

</details>

<details><summary><code>350_more_findings_test.sql</code>: 6 checks</summary>

1. 1. an ask the automation took may have arrived, so "no longer needed" still goes out
2. 2. "no longer needed" for an ask that never went out is still dropped
3. 3. a masked link in a team message on Discord shows its address
4. 4. also when the text is changed
5. 5. emails are not changed
6. 6. text that is not a web link is left alone

</details>

<details><summary><code>360_page_data_test.sql</code>: 2 checks</summary>

1. 2. every foreign key on a table that grows has an index
2. 3. tasks, messages, help requests, reminders, instructor orders and settings are found by what they belong to

</details>

<details><summary><code>370_sooner_class_first_test.sql</code>: 14 checks</summary>

1. 1. the sooner class week asks the Primary
2. 2. the later class week skips the Primary and asks Backup 1
3. 3. the Primary has one open request, not two at the same time
4. 4. the later week says why the Primary is skipped
5. 5. the new sooner class week takes the Primary
6. 6. the later class week asks its next instructor at once
7. 7. the later request is withdrawn because of the sooner class
8. 8. the Primary is told the later class no longer needs them (it had reached them)
9. 9. Activity history says the later class week gave way to a sooner class
10. 10. a request that had not gone out yet is withdrawn without a "no longer needed" message
11. 11. a sooner class week does not take an instructor who is already confirmed for a later one
12. 12. once the clash is gone, the instructor can be asked for that class week again
13. 13. other history reasons stay as they were (Backup 1 was taken off the later 6 February week for the sooner one)
14. 14. a sooner class in another domain gets the instructor, and the later one asks its next instructor

</details>

<details><summary><code>380_schedule_checks_test.sql</code>: 18 checks</summary>

1. 1. unusual before 6 AM or after 10 PM, 30 minutes, 2 classes a day
2. 2. a domain can change the hours, and the warning says so
3. 3. 15 minutes after another class is a tight gap: asked first, not saved
4. 4. nothing is booked until the warning is accepted
5. 5. going ahead needs a reason
6. 6. with a reason it is saved
7. 7. the reason is kept in Activity history
8. 8. a third class on one day is a full day
9. 9. an unavailable instructor cannot be assigned, even with a reason
10. 10. moving a class 10 minutes after the instructor's other class asks first
11. 11. moving a class onto the instructor's unavailable date is refused
12. 12. over the monthly limit is a warning
13. 13. a class at 5 AM is listed with its level and fixes
14. 14. an instructor no longer in use but still confirmed is listed
15. 15. a confirmed instructor at their limit (not over it) is fine
16. 16. a class week that gave way to a sooner class says so
17. 17. problems for several class weeks in one call
18. 18. only the team can read them

</details>

<details><summary><code>390_standard_schedules_test.sql</code>: 22 checks</summary>

1. 1. the module order is saved, with labels for Activity history
2. 2. two standards of one domain cannot share a name
3. 3. a break goes between two modules
4. 4. a module of another domain cannot be in it
5. 5. each module once
6. 6. a class time of the standard belongs to its domain
7. 7. one week per module, and the break week moves the second module back a week
8. 8. the second module uses the standard's own class time
9. 9. the first module uses the module's own class times
10. 10. nothing blocks this plan
11. 11. a name in use, or used twice in one plan, blocks it
12. 12. both cohorts are created with their 4 class weeks
13. 13. each class week knows its place in the standard
14. 14. an India cohort's classes are at India time
15. 15. both follow the standard
16. 16. moving a class makes that cohort Custom (1 change) without touching the other cohort on the standard
17. 17. only that class week is marked
18. 18. a class that took place is not a change
19. 19. an extra class week outside the standard counts as a change
20. 20. a cohort without a standard is fully custom
21. 21. the preview says when the Primary already teaches at that time
22. 22. an archived standard cannot be used for new cohorts

</details>

<details><summary><code>400_standard_reset_apply_test.sql</code>: 20 checks</summary>

1. 1. only the class week that follows the standard and has no instructor is updated
2. 2. a customized week is not updated, with the reason
3. 3. a confirmed week is not updated, with the reason
4. 4. the preview says what moves
5. 5. the clash it would create for the person being asked is shown before saving
6. 6. saving past it needs a decision
7. 7. nothing moved yet
8. 8. with a reason it is saved
9. 9. SR B moved; the customized and the confirmed weeks did not
10. 10. following the standard is not a change of the cohort's own
11. 11. Activity history has it
12. 12. one class week back to the standard, and the cohort is Standard again
13. 13. a whole cohort can be reset
14. 14. a confirmed week moves through the time change flow and keeps its instructor
15. 15. the instructor is asked about the new time
16. 16. a confirmed week never gains or loses a class through a reset
17. 17. without an instructor, a class the standard no longer has is cancelled
18. 18. each cohort gets the new module's class week
19. 19. it is created for the cohorts on the standard
20. 20. a fully custom cohort is never touched

</details>

<details><summary><code>410_standard_fixes_test.sql</code>: 6 checks</summary>

1. 1. a time that happens twice needs a choice, not a reason
2. 2. changing only the module order makes a new version
3. 3. so a second editor is told
4. 4. a module taken out takes its class times with it (and they allow the same days and lengths as a module's)
5. 5. Reset offers to mark it as following its standard
6. 6. and then it does

</details>

<details><summary><code>420_cohort_breaks_test.sql</code>: 30 checks</summary>

1. 1. every class week from the first day moves back by the break
2. 2. each class keeps its clock time, shown before and after
3. 3. the instructors affected are counted
4. 4. the clash the move creates for Instr1 blocks, with its fixes
5. 5. the preview saves nothing
6. 6. saving past a Block is refused
7. 7. releasing Instr1 for that class week lets it save
8. 8. the class weeks moved
9. 9. at the same clock time
10. 10. the break is kept, with a label for Activity history
11. 11. Instr1 is released with the release note
12. 12. the other cohort is not touched
13. 13. Instr3 gets one message for both moved class weeks
14. 14. with Still works, Doesn't work and Propose another time for each class week
15. 15. each class week has its own time change request
16. 16. the message says why and lists every class week
17. 17. no separate time change message per class week
18. 18. Still works for one class week confirms that week
19. 19. the hourly run does not ask again about the other class week
20. 20. two breaks of one cohort cannot overlap
21. 21. a break cannot start in the past
22. 22. a class week with classes on both sides of the first day blocks
23. 23. removing a break moves the classes back, and the later break with them
24. 24. Activity history has both
25. 25. planning a class inside a break warns
26. 26. a program break is one break for every cohort
27. 27. and is removed as one
28. 28. adding a cohort holiday lists the classes on it
29. 29. the class is a problem to fix: move, cancel, or keep with a reason
30. 30. kept with a reason, it is information

</details>

<details><summary><code>430_time_proposals_test.sql</code>: 26 checks</summary>

1. 1. the request to teach offers Propose another time
2. 2. other messages keep their buttons
3. 3. the page shows each class with its date and times in its time zone, and a note
4. 4. the same times are not a proposal
5. 5. a time that does not exist is refused
6. 6. a new time is sent
7. 7. the proposal keeps each class, as it is and as proposed
8. 8. a task goes to the operations team
9. 9. the instructor is told the team will reply
10. 10. nothing changes yet: the request stays open and the class keeps its time
11. 11. the class week shows the proposed time to decide
12. 12. the link does not take a second proposal
13. 13. nothing blocks it
14. 14. accepting confirms the instructor
15. 15. at the proposed time
16. 16. the class keeps its previous time, for the Moved badge
17. 17. the confirmation is sent and the task is done
18. 18. after a time change the class week waits for the instructor to confirm the new time
19. 19. the time change message offers Propose another time too
20. 20. a proposal that clashes with the instructor's other class blocks
21. 21. so it can't be accepted
22. 22. rejecting tells them, with their answers again
23. 23. accepting keeps them confirmed at their proposed time
24. 24. without asking them again about the time they proposed
25. 25. a proposal made before the times changed again can't be accepted
26. 26. Activity history has the decisions

</details>

<details><summary><code>440_shared_classes_test.sql</code>: 20 checks</summary>

1. 1. a guest with another confirmed instructor blocks until Ops chooses
2. 2. the preview says what happens
3. 3. a cohort can't share with itself
4. 4. the preview changes nothing
5. 5. releasing the guest's instructor lets it save
6. 6. the guest class week points to the host and is not asked
7. 7. its instructor is released with the release note
8. 8. each guest class points to its host class, at the same time
9. 9. the instructor is booked once, for the host's classes
10. 10. the guest class follows the host's new time
11. 11. a guest class's time is changed only on the host
12. 12. the host class is not cancelled while it is shared
13. 13. the guest is not resumed while it is shared
14. 14. both class weeks say they are shared
15. 15. different times need a choice
16. 16. taking a guest's times moves the host, and every guest follows
17. 17. and the host's instructor is asked about the new time
18. 18. another module needs a reason
19. 19. the chosen time is checked for odd hours in each cohort's time zone
20. 20. stopping gives the cohort its own class week back, at the shared time

</details>

<details><summary><code>450_cohort_merges_test.sql</code>: 18 checks</summary>

1. 1. never before both cohorts started
2. 2. only at the start of a class week
3. 3. the name must be new
4. 4. from the merge date: the chosen sequence moves, the other cohort's duplicate is cancelled
5. 5. the merge check says which modules do not line up
6. 6. two confirmed instructors: the chosen cohort's stays, the other gets the release note
7. 7. Ops can keep the other instructor instead
8. 8. the preview changes nothing
9. 9. a merge with warnings needs a reason
10. 10. two class weeks move and one is cancelled
11. 11. the combined cohort follows the chosen sequence
12. 12. the cohorts keep their class weeks before the merge date
13. 13. the other instructor gets the release note; the chosen one stays
14. 14. each cohort says it merged into the combined cohort from the date
15. 15. with the chosen cohort's instructor order
16. 16. undo moves the class weeks back and plans the cancelled one again
17. 17. the cohorts are on their own again and the combined cohort is archived
18. 18. Activity history has both

</details>

<details><summary><code>460_schedule_board_test.sql</code>: 12 checks</summary>

1. 1. a confirmed class week
2. 2. waiting for an answer, with who
3. 3. under 12 hours left to answer is a badge
4. 4. needs an instructor
5. 5. paused
6. 6. cancelled
7. 7. a clash is a badge on the cell
8. 8. Needs a decision counts each problem
9. 9. each cohort has its column, with Standard or Custom
10. 10. every module of the domain is on the board
11. 11. a past class week has no problems to decide
12. 12. the board reads at most 27 weeks at a time

</details>

<details><summary><code>470_usage_view_test.sql</code>: 5 checks</summary>

1. 1. the database size, against the free plan's 500 MB
2. 2. n8n runs this month, by workflow
3. 3. the email cap and what is left
4. 4. only admins see usage
5. 5. an admin sees it

</details>

<details><summary><code>480_connection_tests_test.sql</code>: 12 checks</summary>

1. 1. nothing set up: Discord and email are not ready
2. 2. a Discord test needs an approved server, and says how to get one
3. 3. only Discord or Email
4. 4. a test needs a signed in team member
5. 5. a Discord test needs the admin alert channel
6. 6. set up and nothing sent: ready, no messages yet
7. 7. an admin sends a Discord test
8. 8. it posts to the admin alert channel through the usual queue
9. 9. one test a minute
10. 10. an admin sends an email test
11. 11. the email goes to the admin's own address, and both tests are in Activity history
12. 12. only admins can send a test

</details>

<details><summary><code>490_many_discord_servers_test.sql</code>: 14 checks</summary>

1. 1. an instructor's channel can be in server B
2. 2. another instructor's channel can be in server C, for the same domain
3. 3. a channel in a server not approved for this domain is refused, with what to do
4. 4. the domain's alert goes to its channel in server A
5. 5. the first instructor is asked in their channel in server B
6. 6. and by email, as every instructor is
7. 7. the next instructor is asked in their channel in server C
8. 8. the guard lets every one of them out: each channel's own server is approved for the domain
9. 9. an admin approves a new server for the domain later
10. 10. the existing instructors keep their channels
11. 11. the other servers stay approved and the domain's main server is unchanged
12. 12. one task, even when the failure is reported twice
13. 13. the task says what failed and that the email still reached them
14. 14. the instructor is marked, so their Discord channel is checked before the next message

</details>

<details><summary><code>500_trusted_bounces_test.sql</code>: 7 checks</summary>

1. 1. a "bounce" with no thread is ignored
2. 2. a bounce in a thread the app did not start is ignored, even if it looks like a delivery report
3. 3. a bounce for another address than the email in that thread is ignored
4. 4. nothing was changed and no task was raised
5. 5. each ignored one is in Activity history, in plain words
6. 6. a real bounce of an email the app sent counts
7. 7. the address is marked and one task is raised

</details>

<details><summary><code>510_board_bulk_actions_test.sql</code>: 20 checks</summary>

1. 1. one combined preview for both class weeks
2. 2. it says who is asked about the new time
3. 3. the preview changed nothing
4. 4. a move that makes the confirmed instructor teach twice at once is a Block, naming them
5. 5. and nothing is saved while there is a Block
6. 6. saving moves both
7. 7. both two weeks later
8. 8. in Activity history
9. 9. the cancel preview says who is told
10. 9b. the cancel preview names each week with its times as they are now
11. 10. cancelling needs a reason
12. 11. saving cancels both
13. 12. both are cancelled
14. 13. a class week cancelled already is a Block
15. 14. one domain at a time
16. 15. a move onto a holiday is a Warning in the preview
17. 16. saving asks first
18. 17. going ahead needs a reason
19. 18. with a reason it is saved
20. 19. the accepted warning and its reason are in Activity history

</details>

<details><summary><code>520_history_undo_rules_test.sql</code>: 13 checks</summary>

1. 1. the edit is recorded as made by a team member
2. 2. and it can be undone
3. 3. a change made directly in the database cannot be undone
4. 4. nor a change made by a setup command
5. 5. nor one made by loading test data
6. 6. nor one made by the system or the automation
7. 7. nor one with no team member behind it
8. 8. the app is not offered Undo for it
9. 9. and the database refuses to undo it
10. 10. a team member creates a module
11. 11. creating a module is never offered for undo, even to the team member who did it
12. 12. nor is removing one
13. 13. and the database refuses to bring it back

</details>

<details><summary><code>530_answer_due_soon_test.sql</code>: 9 checks</summary>

1. 1. the setting is 12 hours by default
2. 2. an answer due in 6 hours is due soon
3. 3. an answer due in 24 hours is not due soon
4. 4. a class week nobody is asked about has no badge
5. 5. with 48 hours, an answer due in 24 hours is due soon
6. 6. the cohort's own number wins
7. 7. less than 1 hour is refused
8. 8. more than 168 hours (a week) is refused
9. 9. it is on the settings page

</details>

<details><summary><code>540_preview_order_and_plan_checks_test.sql</code>: 10 checks</summary>

1. 1. the class weeks that move are in date order, earliest first
2. 2. and the classes of each class week too
3. 3. Reset to standard lists the class weeks in date order
4. 4. both cohorts that follow the standard change
5. 5. Update cohorts lists every cohort's class weeks together, in date order
6. 6. a proposed time lists its classes in time order
7. 7. one result for each class week of the plan
8. 8. a class on a holiday is a warning
9. 9. a class that ends when it starts is a block
10. 10. nothing is saved, not even the new cohort

</details>

<details><summary><code>550_status_words_test.sql</code>: 14 checks</summary>

1. 1. the practice class names the status in the board's words
2. 2. and still passes every stage
3. 3. nobody asked yet: Not asked yet
4. 4. NotReady: Setup incomplete
5. 5. paused: Paused
6. 6. NeedsInstructor: Needs instructor
7. 7. at risk with nobody asked: Needs instructor
8. 8. Asking: Waiting for an answer, with who is asked
9. 9. Cancelled: Cancelled
10. 10. the same status as the board for every class week
11. 11. a confirmed class week: Confirmed with the instructor
12. 12. a class week not confirmed yet: Not asked yet or Waiting for an answer
13. 13. no owner check in says Asking or a status code
14. 14. the owner check in no longer writes "Asking"

</details>

<details><summary><code>560_live_findings_test.sql</code>: 28 checks</summary>

1. 1. no function writes a dash (only the one that removes them has one)
2. 2. the confirmed page starts with new words under its heading
3. 3. so does the page for a second tap
4. 4. the Need help page labels each checkbox, choice and the details box by its words
5. 5. no control sits inside its label any more
6. 6. the help page names who replies, without a second "Thanks!"
7. 7. the task title has a colon, not a dash
8. 8. the help receipt is waiting to go
9. 9. the instructor releases the class
10. 10. their help request closes with a note
11. 11. and its task is done
12. 12. in Activity history
13. 13. the help receipt that had not gone out is withdrawn
14. 14. the release note still goes
15. 15. the class week no longer shows "Help request open"
16. 16. the next instructor says yes
17. 17. a waiting proposal decision for the cancelled week is withdrawn
18. 18. the class cancelled notice still goes
19. 19. team messages are not touched
20. 20. nothing else waits to go to the instructor about the cancelled week
21. 21. the help request closes with a note
22. 22. and its task is done
23. 23. in Activity history
24. 24. the withdrawn messages are in Activity history too
25. 25. each date and time box is labelled by its own words
26. 26. no box sits inside its label any more
27. 27. each date also shows as "Sun, Jan 31, 2027"
28. 28. and changes with the box, with a small script on the page itself

</details>

<details><summary><code>570_daily_summary_test.sql</code>: 18 checks</summary>

1. 1. one daily system summary to the admin channel
2. 2. its subject is in plain words
3. 3. it starts with its name
4. 4. failed messages in the last 24 hours, not older ones
5. 5. the top reasons, most common first, with how many
6. 6. n8n runs this month against the 10,000 limit
7. 7. a warning above 80 percent of n8n runs
8. 8. the database size against the 500 MB free limit
9. 9. no database warning while it is small
10. 10. no dashes, no e.g. and no old internal words
11. 11. the result has the n8n runs
12. 12. the result has the database size and its limit
13. 13. the result keeps the failed count
14. 14. no warning just under 80 percent
15. 15. n8n warning from 8,000 runs
16. 16. database warning from 400 MB
17. 17. one summary a day
18. 18. only the automation

</details>

<details><summary><code>580_setup_simple_test.sql</code>: 40 checks</summary>

1. 1. an instructor without a contact check can be asked in a live domain
2. 2. the setup check passes with instructors who were not checked
3. 3. and the first of them is asked
4. 4. the check stays as information: still not checked
5. 5. an open contact check task closes by itself
6. 6. and no new one is raised for instructors who were not checked
7. 7. the setup check says who can be asked, without "verified"
8. 8. without test instructors the practice class says what to add
9. 9. two test instructors without a contact check run a whole practice class
10. 10. the welcome text says they are set up and how answers work
11. 11. it is on Settings, Message templates like the others
12. 12. a setting for it, on by default, with the other asking settings
13. 13. choosing an instructor's channel queues one welcome message
14. 14. on Discord, in their channel of that domain, through the normal queue
15. 15. with the welcome text
16. 16. Activity history says it was sent
17. 17. a new channel in the same domain does not send it twice
18. 18. a second domain sends its own welcome, with its own text
19. 19. one per domain
20. 20. adding an instructor sends the welcome by email
21. 21. to their email
22. 22. never twice by email
23. 23. not even from another domain
24. 24. still one
25. 25. switching it off is logged in Activity history
26. 26. with the setting off, choosing a channel sends no welcome
27. 27. the beta rules apply to the welcome
28. 28. Activity history says it was blocked, and why
29. 29. once the reason is gone it is sent
30. 30. once
31. 31. testing sends it to the testing channel
32. 32. a module needs 1 instructor in its order by default
33. 33. the setup step is done with 1 instructor in use
34. 34. the Modules list needs 1
35. 35. and not done with nobody in use in the order
36. 36. the number comes from the setting
37. 37. the setting says what it is for
38. 38. the setup check calls a module that is not live a draft
39. 39. a standard schedule takes live modules
40. 40. the stored value is unchanged: no data moves

</details>

<details><summary><code>590_planned_instructor_test.sql</code>: 18 checks</summary>

1. 1. one answer for one class week
2. 2. the planned instructor is the first of the order
3. 3. with rank 1, the Primary instructor
4. 4. the same person preview_next names as asked next
5. 5. asking starts outreach_days (30) before the first class
6. 6. not paused
7. 7. nobody is being asked
8. 8. a changed setting moves the day asking starts
9. 9. an instructor not in use is skipped: the next one is planned
10. 10. rank 2, Backup 1
11. 11. a paused class week says so
12. 12. a chosen list: the person comes from the list, with no rank
13. 13. after Start asking now: who is being asked
14. 14. confirmed: who is confirmed
15. 15. and nobody is planned any more
16. 16. only a signed in team member can read it
17. 17. the private function and anonymous callers have no access
18. 18. at most 1,000 class weeks at a time

</details>

<details><summary><code>600_live_updates_test.sql</code>: 3 checks</summary>

1. 23. every live table keeps row level security on
2. 24. the app cannot read the list of tables the migration added
3. 25. nor can anyone signed out

</details>

<details><summary><code>610_beta_recipients_test.sql</code>: 18 checks</summary>

1. 1. a real instructor not on the beta list is blocked
2. 2. the message is marked blocked
3. 3. with the reason and what to do
4. 4. once their email is on the beta list, email goes out before any sign in
5. 5. and it is not marked blocked
6. 6. a direct message to their own Discord account goes out
7. 7. one to an instructor who is not on the beta list is blocked
8. 8. with a plain reason
9. 9. Send again while the rule still stops it is blocked again, with the reason
10. 10. once allowed, Send again queues it
11. 11. as a new message that goes out (now, or at the instructor's first sending time)
12. 12. logged in Activity history
13. 13. only an admin changes the setting
14. 14. an admin (here the setup command) switches it off
15. 15. the change is logged
16. 16. with it off, the beta list alone no longer lets a message through
17. 17. a signed in colleague who teaches receives messages
18. 18. queueing a Discord check with the clock on works even when the poke cannot be sent

</details>

<details><summary><code>620_instructor_channel_check_test.sql</code>: 25 checks</summary>

1. 1. a channel link
2. 2. a channel ID
3. 3. a channel mention
4. 4. a name is not a link or an ID
5. 5. a channel in a server not approved for the domain is refused, with what to do
6. 6. someone not found on Discord yet is refused
7. 7. something that is not a link or an ID is refused
8. 8. the check starts
9. 9. and asks the automation to look in Discord
10. 10. which hands it the channel, the server, the instructor and the bot
11. 11. an instructor who cannot see the channel: exactly what to fix
12. 12. and it is not saved as their channel
13. 13. a channel the bot cannot post in: exactly what to fix
14. 14. and it is not saved
15. 15. someone who is not in the server: invite them
16. 16. an answer for a replaced check changes nothing
17. 17. the bot can post and they can see it
18. 18. it is saved as their channel
19. 19. marked Channel ready
20. 20. one welcome is posted in the channel
21. 21. in their channel
22. 22. and logged
23. 23. the welcome goes only once
24. 24. a channel already another instructor's is refused
25. 25. an alert channel is refused

</details>

<details><summary><code>630_live_high_fixes_test.sql</code>: 25 checks</summary>

1. 1. Draft is always allowed
2. 2. Paused is always allowed
3. 3. Testing needs a testing channel and a testing email
4. 4. and setting it says what is missing
5. 5. the status did not change
6. 6. with both, Testing is set
7. 7. Live needs an approved server that is ready, an alert channel and a live module with times and an instructor
8. 8. with all of it, Live has nothing missing
9. 9. checking a server not approved for the domain
10. 10. says so
11. 11. an instructor "Checking" with no check left
12. 12. is told to check again
13. 13. work that never came back fails
14. 14. and the server is no longer "Checking"
15. 15. the clock runs the sweep every time
16. 16. an archived instructor does not block a real person: the account is released to them
17. 17. and it is logged
18. 18. a real holder: the problem says Release from
19. 19. and who holds it
20. 20. Release from works
21. 21. the holder lets go and the account is checked again
22. 22. opening the domain asks for a fresh channel list
23. 23. as a server check
24. 23b. a quiet refresh: the server keeps its status, so a refresh that never comes back is not a problem
25. 24. not again within 2 minutes

</details>

<details><summary><code>640_send_any_hour_test.sql</code>: 24 checks</summary>

1. 1. the India instructor of a US class is asked at 3:00 AM India time
2. 2. and every copy of the request goes at once, not held for the night
3. 3. on Discord and by email, ready to send now
4. 4. the reminder and the deadline keep their usual length (24 and 48 hours)
5. 5. class times are in US Pacific time and India time
6. 6. and so is the reply by time
7. 7. the US instructor of an India class is asked at once at 3:00 AM Pacific time
8. 8. on: 3:00 AM India time waits for 8:00 AM in the instructor's own time zone (India)
9. 9. on: 12:30 PM India time goes at once, though it is 11:00 PM in the class's US time
10. 10. on, no time zone for the instructor: the class's time zone (11:00 PM Pacific waits for 8:00 AM Pacific)
11. 11. off (every other domain): the same moment goes at once
12. 12. on: the request to the India instructor waits for 8:00 AM India time
13. 13. on: the reminder and the deadline still keep their usual length from when it is sent
14. 14. asking the first instructor
15. 15. when the change is saved, the next instructor is asked
16. 16. and the week is Asking with a request open
17. 17. a request closed by a time change: someone is asked again
18. 18. nobody left: Needs instructor, not Asking
19. 19. with the usual task to assign someone
20. 20. the clock finds the week Asking with nobody asked
21. 21. asking cannot happen now: Not asked yet
22. 22. and nobody is messaged
23. 23. a week left Asking with nobody asked: the clock asks the next instructor
24. 24. no class week anywhere is Asking with no request open

</details>

<details><summary><code>650_draft_withdrawn_reply_by_test.sql</code>: 16 checks</summary>

1. 1. a Draft domain queues no instructor message
2. 2. nothing is created or scheduled
3. 3. and history says so
4. 4. back to Draft: the instructor messages still waiting are cancelled
5. 5. with the reason
6. 6. the open request is withdrawn
7. 7. and the week shows Not asked yet, not Asking
8. 8. a message that would still go for a Draft domain is stopped, never silently
9. 9. after a withdrawal the next instructor is asked, not the same one again
10. 10. the line says why
11. 11. a week moved for a break may ask them again
12. 12. the India instructor accepts
13. 13. the time change waits for 8:00 AM in the instructor's own time zone (India), not the class's
14. 14. the refusal for an unapproved server says where it is approved now
15. 15. the purge runs
16. 16. every night at 21:15 UTC where the clock lives

</details>

<details><summary><code>660_live_fixes_kept_test.sql</code>: 14 checks</summary>

1. 1. any hour: 11:00 PM Pacific goes at once while quiet hours are off
2. 2. any hour: the request itself goes at once
3. 3. both times: class times and the reply by time in US Pacific and India time
4. 4. never Asking with nobody asked: the next instructor is asked when the change is saved
5. 5. and the clock still sweeps
6. 6. the check on saving is in place
7. 7. Release from: the Discord result names the holder and offers Release from
8. 8. archived instructors release the account by themselves
9. 9. Release from exists
10. 10. the clock ends checks that never came back
11. 11. a domain status says what is missing
12. 12. a Draft domain creates no instructor message
13. 13. messages use the instructor's own time zone
14. 14. check in reply by times use the instructor's own time zone

</details>

<details><summary><code>670_preview_many_test.sql</code>: 3 checks</summary>

1. 1. the same answer as preview_next for the first week
2. 2. and for the second
3. 3. none asked, none returned

</details>

<details><summary><code>680_channel_check_timeout_test.sql</code>: 3 checks</summary>

1. 1. the Discord work that never came back fails
2. 2. and the channel check ends
3. 3. saying what to do

</details>

<details><summary><code>690_readable_both_times_test.sql</code>: 5 checks</summary>

1. 1. same date: the other time zone without its date
2. 2. another date: with its date
3. 3. an India class: India time first
4. 4. the subject: one time, no brackets inside brackets
5. 5. no brackets inside brackets in any message body

</details>

<details><summary><code>700_contact_instructor_test.sql</code>: 6 checks</summary>

1. 1. an empty message is refused
2. 2. on Discord and by email
3. 3. with the text written
4. 4. the Discord copy goes to their own channel
5. 5. and it is in Activity history
6. 6. nothing goes to an archived instructor

</details>

<details><summary><code>710_message_channel_choice_test.sql</code>: 3 checks</summary>

1. 1. the welcome of domain B goes to their channel in domain B, not an older one elsewhere
2. 2. once
3. 3. a message for no domain goes to their checked channel

</details>

<details><summary><code>720_request_loop_current_rows_test.sql</code>: 9 checks</summary>

1. 1. the sooner week asks the Primary, the later one Backup 1
2. 2. set up: in that run the later week's request is due its reminder
3. 3. the clock run finishes (it failed with "one open request per class week")
4. 4. the sooner week's request ran out
5. 5. the sooner week now asks Backup 1
6. 6. the later week's request stays withdrawn: it is not reopened as Reminded
7. 7. the later week asks its next free instructor, the Primary
8. 8. the later week has exactly one open request
9. 9. Backup 1 gets no reminder and no "no reply" message for the withdrawn request

</details>

<details><summary><code>730_check_needed_test.sql</code>: 22 checks</summary>

1. 1. a message taken 14 minutes ago is left alone
2. 2. after 15 minutes it becomes Check needed
3. 3. it is not handed to the automation again
4. 4. no copy of it is made (nothing is sent again by itself)
5. 5. it says plainly that it is not known whether it arrived
6. 6. the instructor's Discord is not marked as failing (nothing is known to have failed)
7. 7. the operations team gets a task
8. 8. the task says what to check
9. 9. the task names both choices
10. 10. and the team is alerted
11. 11. Activity history says a check is needed
12. 12. one task, not one per run
13. 13. It arrived marks it as sent
14. 14. the message reads Sent
15. 15. the task is done
16. 16. Activity history keeps who checked it
17. 17. a second answer is refused, so it is never sent twice
18. 18. Send again: the old one reads not delivered and one new copy waits to send
19. 19. its task is done
20. 20. a late "sent" answer marks it sent
21. 21. and closes the task
22. 22. someone signed out cannot answer a check

</details>

<details><summary><code>740_reliability_test.sql</code>: 15 checks</summary>

1. 1. the first person assigns an instructor
2. 2. the second person, assigning someone else, is refused with a reason
3. 3. the first choice stands: nothing was overwritten
4. 4. a second save from the same old copy is told to reload
5. 5. and the first save stays
6. 6. the Sunday before the March change: PST, India 13 hours 30 minutes ahead
7. 7. the first Sunday after it: PDT, India 12 hours 30 minutes ahead
8. 8. the Sunday before the November change: still PDT
9. 9. the first Sunday after it: back to PST
10. 10. an India class keeps its India time, and its Pacific time follows the change
11. 11. a weekly US class keeps 9:00 AM Pacific across the change (the week is an hour shorter)
12. 12. a class week cancelled for a holiday gets no request
13. 13. a paused class week gets no request
14. 14. and nobody is asked for either
15. 15. once resumed, the same class week is asked at the next run

</details>

<details><summary><code>750_first_in_line_test.sql</code>: 14 checks</summary>

1. 1. six class weeks compared
2. 2. on every one, the first person who can be asked is the same as the whole line's
3. 3. someone being asked now is skipped
4. 4. someone away is skipped
5. 5. a chosen list comes first
6. 6. a chosen list of someone away continues with the order
7. 7. nobody left when everyone is away
8. 8. planned instructors name the same people
9. 9. Instructor requests shows the same next person as the whole line
10. 10. the domain call covers every coming class week nobody is confirmed for
11. 11. with the same answer for each as planned_instructors
12. 12. four parts at once give every class week once
13. 13. the faster clash check gives the same answer for every instructor and class week
14. 14. and it still finds the real clash

</details>

<details><summary><code>760_testing_replies_and_draft_test.sql</code>: 11 checks</summary>

1. 1. set up: in testing the request email went to the testing mailbox
2. 2. a reply from the testing mailbox in that thread is matched
3. 3. to the test instructor the request was for
4. 4. the task names the instructor, not an unknown sender
5. 5. someone else replying in that thread is not matched by the thread
6. 6. the testing mailbox in a thread the app did not start is not matched
7. 7. outside testing the thread does not stand in for the sender
8. 8. set up: a time change request is open
9. 9. back to Draft withdraws it
10. 10. nothing is left waiting for the instructor
11. 11. and nothing new is sent to anyone

</details>

<details><summary><code>770_admin_fields_and_claim_test.sql</code>: 14 checks</summary>

1. 1. someone who is not an admin cannot make themselves an admin
2. 2. nor give back access an admin removed
3. 3. nor delete an admin
4. 4. nor add a new admin
5. 5. the Team page's own saves still work (name, job title, email, Discord)
6. 6. and adding a colleague who is not an admin still works
7. 7. nothing changed: still not an admin
8. 8. and the access is still removed
9. 9. an admin still makes someone an admin (set_admin does this after its own checks)
10. 10. and it is saved
11. 11. only the message that may still go out is handed to n8n
12. 12. the other is cancelled
13. 13. as blocked, with its reason
14. 14. the allowed one is being sent

</details>

<details><summary><code>780_review_access_test.sql</code>: 44 checks</summary>

1. 1. cannot tick Test instructor
2. 2. cannot change an instructor's email
3. 3. cannot change an instructor's Discord account
4. 4. cannot add an email to an instructor already there
5. 5. nor remove one
6. 6. cannot add a test instructor
7. 7. nor an instructor with a Discord account
8. 8. every other edit still works
9. 9. adding an instructor still works
10. 10. with the extra email typed while adding them
11. 11. cannot change a team member's Discord account
12. 12. nor their own from the Discord prompt
13. 13. but can close the prompt
14. 14. and edit everything else on the Team page
15. 15. an admin ticks Test instructor
16. 16. outside the beta rule the team edits as before
17. 17. a made up team row is no signed in colleague
18. 18. a real account is
19. 19. an email to an address that is not a beta address is blocked
20. 20. one to the colleague's address goes
21. 22. it says to ask an admin
22. 23. the preview says only an admin
23. 24. and a team member cannot delete the domain
24. 25. nor a module
25. 26. nor a team member
26. 27. no direct domain delete
27. 28. no direct module delete
28. 29. no direct cohort delete
29. 30. no direct team member delete
30. 31. no direct status change
31. 32. a new domain starts in Draft
32. 33. renaming still works
33. 34. the only admin cannot be deleted
34. 35. resetting for every domain needs an admin
35. 36. for one domain the team still can
36. 37. an instructor only in draft domains cannot be messaged
37. 38. and nothing was queued
38. 39. an instructor of a live domain can
39. 40. the message belongs to that domain, so its rules apply
40. 41. and its channel is in a server approved for the domain
41. 42. only the setup tables the app edits have write access
42. 43. instructors are deleted only through delete
43. 44. team members too
44. 45. nobody can empty a table

</details>

<details><summary><code>790_review_delivery_test.sql</code>: 19 checks</summary>

1. 1. a late failure for a sent message is ignored
2. 2. it stays Sent
3. 3. a failed message is never put back in the queue
4. 4. a report from an earlier claim is ignored
5. 5. the run that claimed it reports it
6. 6. a first failure is retried
7. 7. without calling n8n at once
8. 8. after about a minute
9. 9. not before
10. 10. and the clock does not call for it yet
11. 11. once due, the clock calls
12. 12. and it is taken again
13. 13. the second retry waits about 5 minutes
14. 14. the third about 15 minutes
15. 15. then it is Failed, with its task
16. 16. Discord's retry_after is kept
17. 17. reply reading slows from 5,000 runs and stops at 8,000
18. 18. immediate calls are batched from 5,000 and stop at 8,000
19. 19. the clock calls less often from 6,500

</details>

<details><summary><code>800_review_email_cap_check_test.sql</code>: 7 checks</summary>

1. 20. only as many emails as the limit leaves
2. 21. Discord messages are not held
3. 22. and no more after that
4. 23. "no longer needed" waits while the ask waits for a check
5. 24. answering "send again" for a closed request works
6. 25. it never arrived, so no "no longer needed"
7. 26. and no new copy of the old ask

</details>

<details><summary><code>810_review_ask_window_test.sql</code>: 16 checks</summary>

1. 27. an ask that never went out is not "No reply"
2. 28. no reminder and no "closed" message for it
3. 29. the deadline moves by the time the ask waited
4. 30. and counts from the send
5. 31. set up: every copy of the ask is blocked
6. 32. one task says the request was not sent
7. 33. and the week does not move on by itself
8. 34. still one task
9. 35. after Pause all the deadline is five hours later
10. 36. a paused domain: three hours later
11. 37. a paused class week: two hours later
12. 38. never later than the first class
13. 39. with nothing held, no reply still moves on
14. 40. a fresh ask still follows its deadline
15. 41. sending it closes the task
16. 42. none of the held requests was ever marked no reply

</details>

<details><summary><code>820_review_replies_resend_test.sql</code>: 7 checks</summary>

1. 1. a reply in domain A's channel belongs to the instructor of that channel
2. 2. in domain B's channel, to B's instructor
3. 3. and that domain's task
4. 16. an automatic reply is recorded as automatic
5. 17. and raises no task
6. 18. two unknown senders on one day share one task
7. 19. which names both

</details>

<details><summary><code>830_review_resend_connection_test.sql</code>: 14 checks</summary>

1. 4. an email sent again goes to the instructor's current address
2. 5. not twice while the first copy waits
3. 6. a channel post goes to their current channel
4. 7. and tags their current Discord account, not the old one
5. 8. an expired login is not a failed message, even when n8n calls it permanent
6. 9. it waits and keeps its tries
7. 10. one alert says the Discord connection is broken
8. 11. nobody's account is marked as failing
9. 12. the same for the email connection
10. 13. a bounce is recorded
11. 14. only once
12. 15. one history entry
13. 20. an action taken 20 minutes ago and never finished is handed out again
14. 21. a fresh one is left alone

</details>

<details><summary><code>840_review_status_effects_test.sql</code>: 3 checks</summary>

1. 22. Draft would withdraw one open request
2. 23. and says how many waiting messages it cancels
3. 24. Testing withdraws none

</details>

<details><summary><code>850_remove_domain_server_test.sql</code>: 37 checks</summary>

1. 1. a normal user cannot remove a server
2. 2. a Live domain keeps its server
3. 3. unchanged
4. 4. an admin removes it from a paused domain
5. 5. there is nothing to remove twice
6. 6. the domain has no server
7. 7. the approval stays, so a server can be chosen again
8. 8. logged once, with who and which server
9. 9. and not a second time as a setup change
10. 9b. a post already waiting is stopped when the automation takes it
11. 10. no channel post
12. 11. with the reason
13. 12. no direct message
14. 13. email still goes
15. 14. a domain that never had a server removed works as before
16. 15. anyone on the team can choose a server again
17. 16. and Discord messages go again
18. 17. a normal user cannot clear it either
19. 18. nor can it be cleared on a Live domain
20. 19. an admin clears it on a draft
21. 20. removed and logged
22. 21. a normal user cannot
23. 22. a domain in use is never part of it
24. 23. and then nothing changes
25. 24. the answer names the domains cleared
26. 25. no server and no approval left on them
27. 26. an archived domain still set to Live is left alone
28. 27. domains in use are untouched
29. 28. one line in Activity history each
30. 29. nothing was sent to anyone
31. 30. deleting the server counts only the domains in use
32. 31. an archived domain does not put its server first
33. 32. a domain in use gets the task
34. 33. an archived domain does not
35. 34. removing access tells the domains in use
36. 35. no archived domain gets a task
37. 36. and none is counted

</details>

### Screen tests (Playwright scenarios)

**`e2e/tests/admin-scenarios.spec.ts`** (11)

1. the Admin page shows who may sign in, the beta list, recipients and the admins
2. an admin adds a colleague to the beta list, and it is logged
3. the last admin cannot remove their own admin rights
4. a server waiting for approval is approved for one domain, and the bot reads it
5. a refused server is never offered to a domain
6. someone who is not an admin sees no admin controls
7. Connections: set up and nothing sent reads Ready; an admin sends a Discord and an email test, both logged
8. Setup, Domains: an admin approves a waiting server for the domain, chooses a server, and the alert channel is right there
9. Setup, Domains: a normal user sees only the servers approved for the domain, and one clear step when there is none
10. a blocked message shows on the instructor with the reason, and goes out after the beta list allows it
11. during the beta, someone who is not an admin cannot tick Test instructor or change emails and Discord

**`e2e/tests/asking-scenarios.spec.ts`** (3)

1. ask the next instructor: the person being asked is skipped politely
2. choose who to ask: two people in a custom order
3. start asking now: a class week not started yet asks the first person in its order

**`e2e/tests/board-scenarios.spec.ts`** (6)

1. select two class weeks and cancel them, with one combined preview and a reason
2. Move shows every selected class week and what changes, and saves nothing until Move
3. Add a break starts from the selection, and one shared class needs two class weeks
4. the board opens at this week, and Earlier still shows the weeks before
5. cohorts without a standard schedule are grouped as No standard schedule
6. By instructor on a phone shows each instructor with their class weeks as cards

**`e2e/tests/break-scenarios.spec.ts`** (3)

1. a break for one cohort: the preview first, then the later class week moves
2. a cohort holiday shows on its class, which can be kept with a reason
3. removing the break moves the class week back

**`e2e/tests/check-needed-scenarios.spec.ts`** (2)

1. Check needed: a task says what to check, and It arrived marks the message as sent
2. Check needed in the class week panel: the message shows it, and Send again sends one copy

**`e2e/tests/discord-scenarios.spec.ts`** (6)

1. Discord servers: refresh, choose a server, see a fix, then its channels
2. an instructor: the app finds the username, a channel is chosen by search
3. a pasted link is checked first; a channel they cannot see is not saved; the suggested one is, with one welcome
4. a username nobody has: the app says what to check, and Check Discord tries again
5. a domain alert channel comes from the list; Discord checks are in Activity history
6. a contact check goes to the instructor channel with a tag, plus email, never twice

**`e2e/tests/filters-scenarios.spec.ts`** (2)

1. Upcoming classes: filter by cohort and status, the choices stay after a reload, and Clear all
2. Schedule board: filter by cohort and status, the choices stay after a reload, and Clear all

**`e2e/tests/help-panel-scenarios.spec.ts`** (8)

1. the panel opens the first time, with every status and badge in one line each
2. close with the X, Escape or the button; focus returns to the button; the choice is remembered
3. the board does not move or change size when the panel opens or closes, and a selection stays
4. search the legend, and Only what is on this board
5. a badge's What is this? opens the panel on the Legend at that item
6. hover or keyboard focus on a class week shows what its status and badges mean
7. on a phone the panel is a full height sheet with a Close button
8. Upcoming classes has the same panel, remembered on its own

**`e2e/tests/lifecycle-scenarios.spec.ts`** (11)

1. domain: create one, archive it (hidden from the list and the menu), then restore it
2. cohort: add an India cohort, rename it, archive and restore it, then delete it
3. holiday: add one, edit it, and remove it after a confirmation
4. class time: change one in place; classes already planned stay as they are
5. module: archive it, restore it, then delete it with its classes after typing its name
6. instructor: Save and add another, then delete one with linked data after typing the name
7. team: add two people with Save and add another, then delete one
8. class week: cancel it, then restore it, and the automation can ask again
9. class week: deleting one with a confirmed instructor asks for the name and tells them
10. domain with classes, confirmed instructors and open requests: delete shows what goes and needs the name
11. a role: removing someone from the escalation contacts asks first and says it is done

**`e2e/tests/live-fixes-scenarios.spec.ts`** (5)

1. a domain status that is not ready says what is missing, with a way to fix each, and does not change
2. a Discord account held by another instructor: Release from them, then it is checked again
3. each domain lists only channels of its own approved server, and says when there is none
4. an instructor can have a time zone, and quiet hours for instructors are off
5. Contact instructor sends a message to their channel and email, kept in Activity history

**`e2e/tests/live-scenarios.spec.ts`** (6)

1. a new task shows on Home without reloading the page
2. a new task shows on the task list without reloading the page
3. Mark done updates the task list at once
4. Activity history shows a new entry without reloading the page
5. a module renamed somewhere else shows on its page without reloading
6. notes on an instructor save by themselves, with a Saved mark

**`e2e/tests/merge-scenarios.spec.ts`** (1)

1. two cohorts merge into a combined cohort, then the merge is undone

**`e2e/tests/proposal-scenarios.spec.ts`** (1)

1. the person being asked proposes a later start; Ops accepts it and they are confirmed

**`e2e/tests/review-scenarios.spec.ts`** (10)

1. R9: arrow keys change no status, and Draft asks first, naming what happens
2. R9: turning on testing for a live domain asks first
3. R10: switching domains with an unsaved setting asks first
4. R11: Send last message again asks first, then sends one copy
5. R23: a class someone else saves keeps what you are typing
6. R37: Contact instructor says what was really queued
7. R40: every class week checkbox says which week it picks
8. R41: the sign in page shows no text taken from the address
9. R34: pressing Assign twice quickly assigns once
10. R35: an edit that cannot be saved as the form closes is said out loud

**`e2e/tests/scenarios.spec.ts`** (16)

1. weekend and weekday cohorts run at the same time
2. the same instructor teaches in two cohorts
3. a confirmed class moves to a weekday and the instructor is asked to confirm
4. a one off class, and a warning accepted with a reason
5. "same instructor" off for one class week
6. settings override at each layer, and reset
7. two people edit the same module: the second is asked to reload
8. owners and the operations team can be reassigned
9. removing a team member's access
10. sign in: a company account gets in, another account is refused
11. editing a message template, preview and reset
12. pausing and resuming all messages
13. a practice class passes every stage
14. a US cohort and an India cohort: time zones, badges and the region filter
15. a time that happens twice asks which one; a time that does not exist is blocked
16. an instructor busy in a US class cannot take an India class at the same moment

**`e2e/tests/server-removal-scenarios.spec.ts`** (3)

1. an admin removes the server of a domain, asked first; a Live domain keeps it
2. archived domains are out of sight and never count; they are cleared at once after a preview
3. someone who is not an admin cannot remove a server

**`e2e/tests/servers-scenarios.spec.ts`** (6)

1. every server is listed with its own status
2. search narrows the list by name or ID
3. Check again checks one server now
4. archive hides a server, Show archived brings it back, and restore
5. delete forgets a server the bot is in, and says the bot stays there
6. an instructor channel can come from a server approved for the domain, checked in Discord first

**`e2e/tests/shared-scenarios.spec.ts`** (1)

1. a class shared by two cohorts, then given back

**`e2e/tests/standard-scenarios.spec.ts`** (6)

1. a standard schedule with two modules and a break
2. two cohorts planned from the standard at once, with every class week shown first
3. one cohort is customized; the other stays Standard
4. Reset to standard brings the class week back
5. the standard changes: its cohorts are updated, except a customized and a confirmed week
6. a cohort added by hand is fully custom

**`e2e/tests/start-scenarios.spec.ts`** (6)

1. an empty app shows only the Get started list, with nothing done yet
2. each step opens the page where it is done
3. the empty pages say what to do next
4. adding a domain in the app ticks the first step
5. a cohort and a team member tick their steps too
6. Get started follows the chosen domain; deleted and archived domains tick nothing

**`e2e/tests/workflow-scenarios.spec.ts`** (7)

1. an instructor answers Yes: the answer page, then a confirmed class on screen
2. a confirmed class: tick a checklist task in the class drawer
3. replacing an instructor: release from the class drawer, the next one is asked
4. reminders: the daily summary is switched off for the domain and back on
5. a help request: the team replies and the instructor is answered
6. assigning by hand: someone who cannot teach those dates cannot be chosen, and the reason shows
7. Home: on it, assign to someone, and mark done with a note

### Unit tests (Vitest)

**`app/src/components/multiSelectLogic.test.ts`** (15)

1. ignores case, accents and extra spaces
2. shows every item when nothing is typed
3. matches every typed word, in any order, without accents
4. matches the hint too
5. matches nothing when a word is missing
6. adds an item that is not chosen, at the end
7. removes an item that is chosen
8. adds several at once, leaving out the ones already chosen and repeats
9. removes one chip
10. changes nothing for an item not chosen
11. moves down and up, wrapping around
12. jumps to the first and last
13. has no active option in an empty list
14. shows the items being saved after the chosen ones, once
15. names the first choice and counts the rest

**`app/src/help/guides.test.ts`** (5)

1. each guide has a title, a summary, a known group and its own number
2. every guide is listed under a group of the Help page
3. every link to a guide opens a guide that exists
4. the question mark on every page opens a guide that exists
5. search finds a guide by its keywords as well as its text

**`app/src/help/images.test.ts`** (2)

1. every picture in the help guides exists
2. every picture in the README and docs exists

**`app/src/lib/autosave.test.ts`** (5)

1. saves text after a pause, with the row version, and then says Saved
2. saves a toggle at once
3. shows a change made somewhere else while there are no unsaved edits
4. keeps unsaved edits and the version they are based on
5. says why a save was refused and does not try the same value again

**`app/src/lib/betaLock.test.ts`** (4)

1. locks people who are not admins while the beta rule is on
2. never locks an admin
3. locks nobody when anyone may receive messages
4. says who to ask

**`app/src/lib/blocked.test.ts`** (6)

1. keeps a blocked message nothing replaced
2. drops it once a later copy went out or is queued
3. keeps it when only an older copy went out
4. treats each channel, kind and class week on its own, newest first
5. ignores cancelled messages that no rule blocked, and replies
6. lists each reason once

**`app/src/lib/channels.test.ts`** (10)

1. reads a channel link
2. reads a link with a message part and spaces around it
3. reads an ID and a <#id> mention
4. refuses anything else
5. lists the usual names
6. suggests the channel named after the full name
7. suggests the first name when nothing better matches
8. prefers the full name over the first name
9. suggests nothing when two channels match equally, or only in another server
10. leaves out channels the bot cannot post in and channels already taken

**`app/src/lib/classTimes.test.ts`** (8)

1. is the live class on Sunday 9:00 AM to 1:00 PM and the review on Thursday 6:00 PM to 8:00 PM
2. names the weekday of a class week that starts on Sunday
3. says the next week for days 7 to 13
4. starts with the live class, then the review, then the live class again
5. gives a copy, so changing the form never changes the defaults
6. moves to the default day and time of the new type while nothing was typed
7. keeps what was typed
8. keeps the day and time for a type without defaults

**`app/src/lib/connection.test.ts`** (6)

1. is Ready, not broken, when set up and nothing was sent
2. is Not set up when a step is missing
3. is Working after a message went out, even after an older failure
4. is a Problem only when the last attempt failed after the last success
5. names the fix for a deleted channel, a missing permission and refused direct messages
6. always suggests a next step

**`app/src/lib/contact.test.ts`** (3)

1. names the channels the message was queued for
2. says when one copy was blocked, and why
3. says when nothing could be sent

**`app/src/lib/discord.test.ts`** (4)

1. asks for exactly four permissions
2. builds the invite link only from a real application ID
3. cleans a username the way the database stores it
4. explains a username problem in plain words

**`app/src/lib/discordNames.test.ts`** (3)

1. replaces a known tag with the person, the team member first
2. handles the nickname form and unknown accounts
3. plain text in history and tasks never shows the codes

**`app/src/lib/domainServers.test.ts`** (4)

1. hides archived domains until they are asked for
2. never counts an archived domain as using a server
3. lists the archived domains to clear: chosen or approved, never one still set to Live
4. names a server it does not know yet

**`app/src/lib/domainStatus.test.ts`** (6)

1. asks before every change to Draft, naming what is withdrawn and cancelled
2. asks before leaving Live, saying what happens to open requests
3. asks before going live and before leaving testing
4. asks nothing when nothing is at stake
5. counts one request in the singular
6. stops arrows and letters, keeps keys that open it or move on

**`app/src/lib/fetchAll.test.ts`** (4)

1. reads every page until one comes back short, so nothing past 1,000 rows is lost, three pages at a time after the first
2. asks once when everything fits on one page, and passes on an error
3. sends a long list of IDs 100 at a time and joins the results
4. asks nothing for no IDs, and passes on an error

**`app/src/lib/filters.test.ts`** (18)

1. nothing chosen matches everything
2. choices within one field are OR
3. fields are AND
4. a field with several values per item (badges) matches when any of them is chosen
5. an item with no value in a chosen field does not match
6. a field the getters do not know is skipped (checked elsewhere, such as each class)
7. ticks, unticks and flips one value
8. sets or clears one field and leaves the others
9. counts the choices
10. a chosen value missing from the list is still offered, so it can be unticked
11. chips follow the field order and read the option label
12. options from the data are distinct and sorted by label; fixed options keep their order
13. each page has its own key per signed in person
14. nothing saved yet starts with nothing chosen
15. broken or unknown saved text starts with nothing chosen
16. keeps the shape { version, domains: { domain ID: { field: values } } }
17. a domain with nothing chosen is dropped
18. reads only the fields of the page, as distinct strings

**`app/src/lib/helpPanel.test.ts`** (9)

1. keeps everything with no search and the switch off
2. finds items by a word of their label or their meaning, without case
3. needs every word typed
4. with Only what is on this page, keeps only the labels shown, matched without case or punctuation
5. drops groups left empty
6. gives the one line meaning of a label as shown
7. makes the same id for the same label however it is written
8. opens the first time, then follows the last choice
9. is kept per page and per person

**`app/src/lib/historyText.test.ts`** (31)

1. describes a single move in the instructor order
2. never shows ids or raw field names for an edit
3. says Draft and Live for a module status, never the stored values
4. names messages instead of template codes
5. names messages whose route has several words (decision 272)
6. describes settings with their labels
7. removes dashes and applies the glossary
8. reads a no reply the old way (a dash) and the new way (a comma)
9. describes going live, pausing messages and downloads
10. names the level of a settings override and escalation contacts
11. names the parts of a standard schedule
12. says when a standard schedule is archived
13. describes planning from a standard, Reset to standard and updating cohorts
14. names a break and a cohort holiday
15. says who added or removed a break
16. says who proposed, accepted or rejected a time
17. says who shared a class and who gave a cohort its own class back
18. says who merged cohorts and who undid it
19. lists what changed, field by field, with no ids or database field names
20. lists the fields of a new record, naming what its ids point to and leaving out unknown ones
21. shows a setting by its name and the reason given, never its key
22. reads nested data and lists without raw data
23. never shows an id, JSON or a field name with an underscore
24. leaves out an undo note, which only names an entry number
25. is offered for a team member editing a setup record
26. is not offered when the database says no
27. is never offered for the system, the clock, the automation, a setup command or test data
28. is never offered for creating or removing a module, domain or cohort
29. is not offered for actions that are not setup changes, or for an undo
30. says who removed which server from which domain, with no raw fields
31. is not offered for undo

**`app/src/lib/live.test.ts`** (5)

1. marks only the lists that read the table
2. names a list of a table that is not live by itself
3. marks every list except the previews when a change reaches everything
4. knows which lists read every live table
5. finishes only after the marked lists have loaded again

**`app/src/lib/plain.test.ts`** (5)

1. removes dashes
2. uses the glossary terms
3. uses the words of the team for database values (UI-5)
4. joins class dates with "and"
5. names messages

**`app/src/lib/planCheck.test.ts`** (3)

1. puts the answer on the class week it was asked for
2. ignores an answer for a class week changed again since
3. skips a class week removed meanwhile, and uses each answer in order

**`app/src/lib/planned.test.ts`** (12)

1. names the place in the instructor order
2. says Chosen list for a list picked by hand
3. before anyone is asked: who is planned and the day asking starts
4. shows the day in the class week time zone
5. once asked: waiting for an answer from that person
6. once confirmed: who is confirmed, even if a request is still open
7. says when nobody can be asked, and nothing for a finished week
8. a paused week is not asked
9. waits for the setup to be complete
10. soon when the day has come, or the week is at risk
11. lets a week with a planned person start
12. gives the reason otherwise

**`app/src/lib/region.test.ts`** (9)

1. shows a US winter class in PST with the India time
2. keeps 9:00 AM after the March 14, 2027 clock change (PDT)
3. keeps 9:00 AM after the November 7, 2027 clock change (PST)
4. shows India classes in IST only
5. shows the India day when it differs from the US day
6. finds a time that does not exist (clocks move forward)
7. finds a time that happens twice (clocks move back)
8. India has no daylight saving
9. labels the time field with the zone for that date

**`app/src/lib/resend.test.ts`** (4)

1. takes the newest message to the current instructor only
2. never offers a closing or cancellation notice
3. offers only one that went out, failed or was blocked
4. offers nothing when nobody is booked or being asked

**`app/src/lib/share.test.ts`** (5)

1. asks for a choice while the times differ and nobody chose
2. choosing this class week sends its own ID, so the database knows it was chosen
3. shows this class week when the times are the same or not known yet
4. makes the choice again when the times were those of the class week taken out
5. keeps another choice

**`app/src/lib/signIn.test.ts`** (4)

1. shows the reasons the database gives
2. never shows other text from the address
3. tries again after a failure and returns the answer
4. gives up after the last wait

**`app/src/lib/time.test.ts`** (13)

1. shows PST in winter
2. shows PDT on the first PDT Sunday, same wall-clock time
3. formats ranges
4. extracts PT date/time for editing
5. builds weekly Sundays
6. parses a pasted date list in several formats
7. knows Sundays
8. checks emails
9. checks Discord IDs are 17 to 20 digits
10. extracts server and channel IDs from a channel link
11. restricts sign-in to the company domain
12. quotes commas, quotes and newlines
13. says how long ago in words, not abbreviations

**`app/src/lib/week.test.ts`** (4)

1. starts on the Sunday in Pacific time
2. is still last week on Sunday morning in India, while it is Saturday in the Pacific
3. turns over at midnight Pacific
4. puts a class week in this week by its week date, the same on every page

**`app/src/pages/boardBadges.test.ts`** (11)

1. has an entry for every badge the board and its side panel can render
2. names every badge the task list asks for
3. shows each label once
4. explains each badge in one short plain sentence
5. has words for every badge code the database can put on a cell
6. counts in Needs a decision use the badge or status words
7. the Legend lists exactly the agreed statuses, in order
8. no badge or Legend entry uses an old status word
9. gives every database status the agreed word
10. names the instructor in the download words, and keeps at risk as a flag
11. shows a shared class week with the status of the class week it is taught in

<!-- scenarios:end -->
