title: Discord
summary: Connect each domain's Discord server, add usernames, choose channels, and see who gets which message.
order: 6.7
---

The app uses the Discord servers you already have. It never creates servers or channels. A **bot** is the app's own Discord account: it posts the messages and finds people.

## Connect a domain's server

![Discord servers](/help/discord-servers.png)

1. Open [Connections](/settings/connections) and find **Discord servers**.
2. Press **Open the invite link** and add the bot to the server. It asks for only four permissions: View Channels, Send Messages, Embed Links and Read Message History.
3. In Discord, open the category where instructors have their own channels (usually **1-1**), choose **Edit Category**, then **Permissions**, and allow the bot's role the same four permissions.
4. Back in the app, press **Refresh servers**, then choose the server of each domain.
5. Wait for **Ready**. If it says **Needs a fix**, it says exactly what to change. Press **Check** after you fix it.

## Instructors

1. Open [Instructors](/setup/instructors) and open the instructor.
2. Type their **Discord username**, for example maya.k (without @). You see it under their name in Discord.
3. Press **Save**. The app finds their Discord account by itself and shows **Discord found**. If it shows **Not found on Discord**, check the spelling and that they joined the server, then press **Check Discord**.
4. Under **Their channel in each domain**, choose their channel. Type part of the name to find it quickly.

> You never need a Discord user ID. The app finds it from the username.

## Team members

A Discord username is optional. The app asks for yours once after your first sign in. People without Discord get email instead.

## Who gets what

- **Requests to teach, reminders and help replies:** a post in the instructor's channel that tags them, plus an email. Without a channel in that domain, a direct message plus an email.
- **Confirmation:** a post in the instructor's channel that tags the instructor, every owner and the operations team, plus a direct message and an email to the instructor.
- **Team alerts:** a post in the domain's alert channel that tags the people concerned. Each of them also gets a direct message, or an email when they have no Discord.
- **Replacing an instructor:** the first instructor gets a thank you and release note in their own channel. The new instructor gets the confirmation in theirs.
- Nobody gets the same message twice.

## When a message fails

The operations team gets an email and a task on [Home](/) that says exactly what to fix, for example "The Discord channel #maya no longer exists. Choose a new channel". Every Discord check and message is in [Activity history](/activity) under **Discord**.
