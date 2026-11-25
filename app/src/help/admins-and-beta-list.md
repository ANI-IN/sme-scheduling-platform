title: Admins, the beta list and the team
summary: Who may sign in, the beta list, who may receive email and Discord messages, adding admins, and the Team page.
order: 3
group: Setup
keywords: admin, beta list, sign in, access, allowed email domain, who may receive messages, recipients, emails a day, make admin, team member, remove access, give access back
---

Admins decide who may use the app and who may get messages. Only admins see [Admin](/settings/admin) in the menu, under Settings. Every change on it is saved in Activity history. If you are not an admin and need a change, ask an admin.

![Who may sign in and the beta list on the Admin page](/help/admin-sign-in.png)

## Who may sign in

Under **Who may sign in**, choose one of two buttons. The badge on the right shows the current choice.

- **People on the beta list:** only colleagues on the beta list get in. Anyone else is signed out at once and cannot sign in again until an admin adds them.
- The button that starts with **Anyone with an @** lets everyone with a company Google account sign in, whether or not they are on the beta list.

Refused sign ins are listed in Activity history.

## Add someone to the beta list

1. Under **Beta list**, type their **Email**. Only company addresses work.
2. Add a **Note (optional)**, for example their team.
3. Press **Add to the beta list**.

Add yourself first, then your colleagues. Each person shows **Signed in before** or **Not signed in yet**. **Take off the list** signs them out at once if they are signed in. Their work stays.

## Who may receive messages

Under **Who may receive messages**, choose who email and Discord messages may reach. The app checks every person a message goes to or tags, when it is queued and again when it is sent.

![Who may receive messages on the Admin page](/help/admin-messages.png)

1. Fill in **Email only to these domains**: the address endings email may go to, separated by commas. Leave it empty to allow any address.
2. Fill in **Emails a day at most**. Google allows about 2,000 a day for the whole mailbox. Over the limit, emails wait.
3. Press one of the two buttons to save:

- **Test instructors and signed in colleagues** is the beta setting. Real instructors are never contacted, direct messages go only to colleagues who have signed in, and messages may only tag them. Blocked messages are listed in Activity history.
- **Anyone** lets messages reach real instructors again. Do this only when the beta is over.

While the beta setting is on, only an admin ticks **Test instructor**, changes an instructor's emails or Discord
account, or a team member's Discord account. Everyone on the team keeps every other edit.

Only an admin deletes a domain, cohort, module or team member.

Test instructors are explained in [Instructors and the instructor order](/help/instructors).

## Add an admin

Under **Admins**, everyone who has signed in is listed. Admins show **Admin**, and you show **You**.

1. Press **Make admin** next to the person and confirm.
2. To take it back, press **Remove admin rights**.

There is always at least one admin, so the last admin cannot lose their rights. Only people who have signed in can be admins. Admins can change who may sign in, who may receive messages, Discord server approvals, **Pause all messages**, and every setting that affects everyone.

## The Team page

[Team](/setup/team) lists everyone who uses the app. Module owners, the operations team and escalation contacts are chosen from it.

1. Press **Add team member** to add someone before they sign in, or let them appear after their first sign in.
2. Open a person to change their **Discord username (optional)**, **Job title** and **Send a daily summary**.
3. Press **Send test alert** to check that Discord or email reaches them.

People who are not **In use** are not tagged or reminded.

## When someone leaves

1. An admin opens the person on [Team](/setup/team) and presses **Remove access**.
2. They cannot sign in any more and are no longer tagged or reminded. Their past work stays in Activity history.
3. **Give access back** undoes it.

You cannot remove your own access.
