title: Troubleshooting
summary: What the Connections page shows, how to send a test, where to look in Activity history, and what to do when messages, Discord or email do not work.
order: 13
group: Fixing problems
keywords: troubleshooting, connections, working, problem, not set up, send a test, email not working, Discord not working, message failed, not delivered, can't sign in, nobody asked, skipped, errors in the app
---

Start on [Connections](/settings/connections), under Settings. It shows whether the app can reach Discord and email right now.

![Connections](/help/connections.png)

## Connection health

Each line under **Connection health** has a status:

- **Working:** the last message went out.
- **Ready, no messages yet:** set up, but nothing has been sent yet. This is normal after setup.
- **Not set up:** a step is missing. The line says which one.
- **Problem:** the last attempt failed after the last message that went out. The line says what failed and what to fix.

The lines are **Automatic check** (it should run every hour), **Discord**, **Email**, **Automation service** (with the messages waiting to send) and **Daily system summary**. Times are in your time zone.

## Send a test

Admins see **Send a test** on the Discord and Email lines.

- On **Discord**, it posts a test to the admin alert channel.
- On **Email**, it sends a test to your own address.

Each test arrives within a minute and is saved in Activity history. Use it after any change, to check both work in one click. To check that one person is reached, open them on [Team](/setup/team) and press **Send test alert**.

## When a message failed

1. Open the task **Message not delivered** on [Home](/). It says exactly what to fix, for example a channel that no longer exists or a username that was not found.
2. Fix it: choose a new channel or correct the username on [Instructors](/setup/instructors), or the alert channel on [Domains](/setup/domains).
3. Open the class week, open **More options** and press **Send last message again**.
4. Press **Mark done** on the task.

On Instructors, **Only show** with **Messages failing** lists everyone whose messages fail, with **Email bounced** or **Discord message failed**. See [Fixing problems on a class week](/help/fixing-problems).

## When Discord is not working

1. On Connections, look at the **Discord** line and, under **Discord servers**, the status of each domain's server.
2. If a server says **Needs a fix**, do what the line says, for example give the bot's role access to the instructors' category. Then press **Check** next to the domain.
3. If an instructor shows **Not found on Discord**, check the username on their record and that they joined the server, then press **Check Discord**.
4. Press **Send a test** on the Discord line.

While Discord does not work, instructors still get every message by email. See [Domains and the Discord server](/help/domains-and-discord).

## When email is not working

1. On Connections, look at the **Email** line. A **Problem** says what failed.
2. Check **Emails a day at most** on Settings, Admin. Over the limit, emails wait.
3. Check **Email only to these domains** on Settings, Admin: an address outside them is blocked, and the block is listed in Activity history.
4. Press **Send a test** on the Email line.

If **Automatic check** or **Automation service** shows **Problem** or **Not set up**, nothing is sent at all. Tell whoever looks after the app.

## Look in Activity history

[Activity history](/activity) shows what happened last: each message with its status, each answer and each change. Filter by **Type of change**, for example **Messages** or **Discord**, and open **Show details**. See [Reading the Activity history](/help/activity-history).

## Common questions

### Nobody is being asked for a class week

1. Open the class week. If it shows **Setup incomplete**, the task on Home says what is missing.
2. If it shows **Not asked yet**, asking starts later (30 days before by default). Press **Start asking now** under **More options** to start today.
3. If it shows **Paused**, press **Resume requests**.
4. If it shows **Needs instructor**, everyone in the order said no or could not be asked. Add instructors to the order, or use **Ask a specific person** on Instructor requests.

### An instructor is skipped

Open the module's **Who we ask next** tab. It shows the reason for each person, for example not available that day, already teaching at that time, or contact details not checked.

### I can't sign in

Use your company Google account. During the beta, only people on the beta list can sign in: ask an admin to add you on Settings, Admin. If your access was removed, an admin can give it back on the Team page.

### The same error keeps coming back

**Errors in the app** at the bottom of Connections lists problems people ran into while using the app. If you see the same error many times, tell whoever looks after the app.

**Advanced: links** shows the sender email and two links. The links are set by whoever installs the app and cannot be changed here.
