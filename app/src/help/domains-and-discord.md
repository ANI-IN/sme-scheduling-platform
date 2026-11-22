title: Domains and the Discord server
summary: Create a domain, choose its Discord server, approve a waiting server, pick the alert channel and set its status.
order: 2
group: Setup
keywords: domain, Discord server, bot, invite link, approve, waiting for approval, alert channel, escalation contacts, operations team, status, draft, testing, live, class types, holidays, archive
---

A domain is a program area, for example Backend or Fullstack. Each domain has its own modules, cohorts, people, settings and status. Everything about a domain is in one panel on [Domains](/setup/domains): select the domain's row to open it.

![The domain details](/help/domains-drawer.png)

## Create a domain

1. Open [Domains](/setup/domains) and press **Create domain**.
2. Enter the **Domain name**.
3. To start from another domain's automation settings, class types and message texts, choose it under **Copy settings from another domain (optional)**. Otherwise keep **Start with the defaults**. Modules and people are never copied.
4. Press **Create domain**.

A new domain starts as **Draft**, so nothing is sent until you are ready. In the panel, changes save as you make them, except the name and the alert channel: press **Save changes** for those.

## Choose the domain's Discord server

The app uses the Discord servers you already have. It never creates servers or channels. The bot is the app's own Discord account: it posts the messages and finds people.

![The Discord server, a server waiting for approval and the alert channel in a domain's panel](/help/domain-discord-server.png)

1. Open the domain's panel. Under **Details**, find **Discord server**.
2. Choose the server. Only servers an admin approved for this domain are listed.
3. The app checks the server at once and shows its status under the list. Wait for **Ready**.
4. If it says **Needs a fix**, the line underneath says exactly what to change. After you fix it in Discord, press **Check** next to the domain under **Discord servers** on [Connections](/settings/connections).

A server's status is **No server chosen**, **Not checked yet**, **Checking**, **Ready** or **Needs a fix**.

If no server is listed, the panel says so. Add the bot to your Discord server with **Open the invite link**, then an admin approves the server.

## Approve a waiting server (admins)

When the bot joins a new server, the server waits for an admin. Until it is approved, the bot does nothing there.

1. If you are an admin, the domain's panel lists **Servers not approved for a domain yet** under the server list. Each one shows **Waiting for approval** or **Not approved for any domain**.
2. Press **Approve for this domain** next to the right server. The approval is saved in Activity history.
3. Choose the server under **Discord server**.

Admins can also approve servers on [Connections](/settings/connections), under **Discord servers**. Press **Refresh servers** to see servers the bot joined, then **Approve** and tick the domains that may use it. **Refuse** and **Remove access** stop the bot on a server.

![Discord servers](/help/discord-servers.png)

## Let the bot into the instructors' channels

1. Add the bot with **Open the invite link**. It asks only for View Channels, Send Messages, Embed Links and Read Message History.
2. In Discord, open the category where instructors have their own channels (usually 1-1), choose Edit Category, then Permissions.
3. Allow the bot's role the same four permissions.

Each instructor's own channel is chosen on their record. See [Instructors and the instructor order](/help/instructors).

## Alert channel

The alert channel is the Discord channel where the team is tagged about this domain.

1. In the domain's panel, under **Details**, choose the **Alert channel**. Type part of the name to find it quickly.
2. Press **Save changes**.

## People for the domain

- **Escalation contacts** are told when an urgent problem is not fixed in time. Press **Add an escalation contact**.
- The **Default operations team** handles class tasks, failed messages and written replies for every module, unless a module has its own operations team. Press **Add a person**.

People are chosen from the [Team](/setup/team) page.

## Status and testing

The **Status** at the top of the panel decides what is sent:

- **Draft:** being set up. Nothing is sent.
- **Testing:** messages go only to the testing channel and testing email.
- **Live:** real instructors are asked and reminded.
- **Paused:** no messages to instructors. Requests wait until it is turned back on.

The testing channel and testing email are set on [Testing](/settings/testing), where you also turn on testing. Choosing **Live** asks you to confirm, because real instructors are contacted from the next automatic check. See [Testing safely and going live](/help/testing-and-going-live).

## More in the domain's panel

- **Cohorts and regions:** see [Cohorts and planning classes](/help/cohorts).
- **Breaks and cohort holidays:** see [Breaks, cohort holidays and merges](/help/breaks-and-holidays).
- **Class types:** the kinds of class, for example Live class, Assignment review or Office hours. Type a name under **New class type** and press **Add**.
- **Holidays:** days off for US classes, India classes, or both. Planning a class on a holiday gives a warning. See [US and India classes](/help/us-and-india-classes).

## Archive or delete a domain

**Archive** hides the domain and stops its automation. Press **Restore** to use it again. **Delete permanently** removes the domain and everything in it for good. It first shows exactly what goes with it. When other data goes with it, you type its name to confirm.
