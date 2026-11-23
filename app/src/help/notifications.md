title: Notifications and reminders
summary: What instructors get and when, team alerts, the daily summary, reminders, and quiet hours for US and India classes.
order: 15
group: Messages and settings
keywords: notification, message, request to teach, confirmation, reminder before class, team alert, alert channel, daily summary, quiet hours, India, IST, night, automatic check, timeline, email, Discord, direct message
---

The app runs an **automatic check** every hour. Each time, it does what is due for every class week. Messages go out within a few minutes, and a reply an instructor types by email or in their Discord channel shows up as a task within 6 minutes.

## What instructors get, and when

![What happens before a class](/help/timeline.png)

With the default settings:

1. **45 days before:** the setup check. Missing class times, owners or instructors are reported to the owner. Instructors get nothing yet.
2. **30 days before:** the Primary instructor gets a **request to teach** with **Yes, I can teach**, **No, I can't** and **Propose another time**.
3. **No reply:** a reminder about the request after a while, then the request closes and the next instructor is asked. The closer the class, the shorter the wait.
4. **First yes:** that instructor gets a **confirmation** with every class time and how to get help before class. Everyone else who was asked is told politely that the request has closed.
5. **14 days before:** the module owner is asked if everything is ready.
6. **10 and 2 days before:** **reminders before class**. The instructor answers **All set**, **Need help** or **Can't make it**.

Instructors also get a message when a class time changes (they answer **Still works** or **Doesn't work**), when classes move for a break, when a class is cancelled, when they are released, about their proposed time, the **welcome message** when they are added, and the **contact check** if you send one. The exact days are on [Automation](/settings/automation) and can differ per cohort.

## How a message reaches an instructor

- **Requests, reminders and help replies:** a post in the instructor's own channel in that domain that tags them, plus an email. Without a channel in that domain, a direct message on Discord plus an email.
- **Confirmation:** a post in the instructor's channel that tags the instructor, every owner and the operations team, plus a direct message and an email to the instructor.
- **Replacing an instructor:** the first instructor gets a thank you and release note in their channel. The new instructor gets the confirmation in theirs.
- Nobody gets the same message twice.

The texts are on [Message templates](/settings/messages). See [Changing settings and message texts](/help/changing-settings).

## Team alerts

Team alerts go to the domain's alert channel and tag the people concerned, for example when requests start, when an instructor confirms or says no, when nobody is left to ask, when a class week is at risk, for a help request, or when a task is overdue. Each person tagged also gets a direct message, or an email when they have no Discord username.

The people come from the module's owners and operations team, and the domain's escalation contacts. See [Domains and the Discord server](/help/domains-and-discord).

## The daily summary

Each team member with **Send a daily summary** ticked on the [Team](/setup/team) page gets one message each morning at 10:00 AM India time with the tasks waiting for them. Choose **Discord**, **Email** or **Discord and email** under **Send it by**. Nothing is sent when there is nothing to do.

![A team member's Discord username and daily summary](/help/team-member.png)

Admins also get the **daily system summary** in the admin alert channel, set on [Connections](/settings/connections).

## Reminders

All reminders are under **Reminders** on [Automation](/settings/automation), in three parts:

1. **While we wait for an answer:** a reminder to the instructor before the next instructor is asked.
2. **After an instructor is assigned:** reminders before class on the days you list, and questions to the module owners and the operations team about class tasks.
3. **Open tasks for the team:** repeat reminders about open tasks, the messages to the escalation contacts, and the daily summary.

You can switch any of them off, or set a number to 0. Turning reminders off never stops the main work: instructors are still asked in order, the next instructor is still asked when there is no answer, and urgent alerts, for example a cancellation or nobody left to ask, are always sent.

## Quiet hours

Messages to instructors go as soon as they are ready, at any hour, wherever the instructor lives. The operations team decides who teaches, so the app does not hold messages for anyone's night.

An admin can turn on **Quiet hours for instructors** for one domain, on [Automation](/settings/automation) under **More options**, **Quiet hours**. It is off for every domain until someone turns it on. When it is on:

- No message goes to an instructor from 9:00 PM to 8:00 AM by default, in the instructor's own time zone when it is set on their record, otherwise in the time zone of their class.
- Very close to the class (the last 3 days by default), the quiet time is shorter: from 10:00 PM to 7:00 AM.
- How long an instructor has to answer, and when the reminder comes, keep their usual length.

Reminders to the team about tasks that are not urgent wait from 8:00 PM to 9:00 AM India time, as before.

## Close and very close to the class

- **Close to the class** (10 days by default): problems are urgent and replies are expected faster.
- **Very close to the class** (3 days by default): replies are expected fastest.

> To stop every message to instructors at once, see [Pausing all messages in an emergency](/help/pausing-messages).
