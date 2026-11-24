# Operations guide

For the people who plan classes every day. Plain steps, the words you see on screen, and what to do when something
needs you. The same guides are in the app: press **Help** in the sidebar, or the **?** next to any page title.
Pictures of every page are in `docs/screenshots/final/` (see its index).

## Your daily routine

1. Open **Home**. Look at **Needs your attention**. Urgent tasks are at the top.
2. For each task press **I'm on it**, do what it says, then press **Mark done**.
3. Open the **Schedule board**. Look at **Needs a decision** at the top. Press a number to see only those class
   weeks.
4. Look at your domain's alert channel in Discord.
5. Once a week, open **Upcoming classes** and check the next month: every class should be **Confirmed**.

## What the words and colours mean

### The status of a class week

| You see | Colour | What it means | What you do |
|---|---|---|---|
| Confirmed | Green | An instructor said yes | Nothing |
| Confirmed, at risk | Green with a warning | Confirmed, but something may stop it (for example a clash) | Open it and read the warning |
| Waiting for an answer | Amber | An instructor has been asked | Nothing; the app reminds them and moves on if they do not answer |
| Needs instructor | Red | Everyone in the instructor order was asked or cannot be asked | Phone people, then **Assign and confirm instructor**, or add instructors to the module's order |
| Proposed time | Purple | The instructor suggested another time | Open it, look at the new time, then **Accept proposed time** or **Reject** |
| Not asked yet | Grey | Asking starts later (30 days before the class by default) | Nothing, or **Start asking now** |
| Setup incomplete | Grey | Something is missing, for example class times or an instructor order | Open it; it says what to add |
| Paused | Grey | Asking is paused for this class week | **Resume requests** when ready |
| Cancelled, Completed | Grey | Finished | Nothing |

### Marks on the Schedule board

Press **Legend** on the board to see every mark with its meaning. The ones that need you most:

| Mark | What to do |
|---|---|
| Clash | The instructor teaches somewhere else at the same time. Move a class or ask someone else |
| Unavailable | The instructor said they are away. Ask someone else |
| Holiday, Cohort holiday | The class falls on a holiday. Move it, cancel it, or keep it and write why |
| Message failed | A message did not arrive. The task says what to fix; then **Send again** |
| Message not sent | The beta rules stopped it. The reason is shown; fix it, then **Send again** |
| Answer due soon | The instructor has not answered and the time is nearly up |
| Help request open | An instructor pressed Need help. Open it and answer |
| Daylight saving | The class is on the night the clocks change. Check the time |

## When something needs you

| You see | What to do |
|---|---|
| Needs instructor | Phone people. Then open the class week and press **Assign and confirm instructor**, or add instructors to the module's order |
| A written reply | Read it and decide. Press **Reply** to answer the instructor in Discord and by email |
| A message was not delivered | Do what the task says (for example choose a new channel). Then open the class week and press **Send again** |
| Check if a message arrived | The automation never said whether it was sent, so it is not sent again by itself. Look in the instructor's channel or the email. Press **It arrived, mark as sent** or **Send again** (on the task or in the class week's Activity) |
| An email bounced | Fix the email on Setup, Instructors. Discord is still used meanwhile |
| An instructor cannot teach any more | Open the class week and press **Release instructor**. The app asks the next person |
| A proposed time | Open the class week, look at the new time and any problems, then **Accept proposed time** or **Reject** |
| A help request | Press **Open help request**, then **I'm on it**, write your answer and press **Send reply** |
| "This changed, reload" | Someone else saved the same thing. Reload the page and make your change again |
| Someone cannot sign in | Ask an admin to add them to the beta list on Settings, Admin |

## How to add things

### An instructor

1. **Setup, Instructors**, **Add instructor**.
2. Full name and email. If they prefer a limit, **Classes a month**. If you know where they live, **Time zone**
   (India or US Pacific).
3. Their **Discord username**, for example maya.k, without @. Press **Add instructor**. The app finds their Discord
   account by itself and shows **Discord found**.
4. Open them again. Under **Their channel in each domain**, choose their channel, paste its link, or press the
   suggested one. The app checks it in Discord first, then says **Channel ready** and sends one welcome that tags them.
5. Add them to each module's **Instructor order** (Setup, Modules, the module, Instructor order).

### Writing to an instructor yourself

Open them on **Setup, Instructors**, write under **Contact instructor** and press **Send message**. It goes to their
own channel and by email, signed with your name, and is kept in Activity history.

### A domain

1. **Setup, Domains**, **Add domain**. It starts as **Draft**: nothing is sent.
2. In its panel: the **Discord server** (an admin approves it for the domain right there), the **Alert channel**,
   the team, cohorts and holidays.
3. To try it: under **Testing**, choose a testing channel and a testing email, then set the status to **Testing**.
   Every message then goes only there.
4. To go live: the panel says exactly what is still missing, with **Show me** or **Fix this** next to each item. When
   nothing is missing, choose **Live**.

### A Discord server and channels

1. Invite the bot to the server (an admin; see the in app guide **Domains and Discord**).
2. **Setup, Domains**, the domain, **Discord server**: choose it, and an admin presses **Approve for this domain**.
3. New channels appear by themselves within a couple of minutes.

### A module

**Setup, Modules**, **Add module**: name, class times (Sunday 9:00 AM to 1:00 PM and Thursday 6:00 PM to 8:00 PM
Pacific by default), owners, and the instructor order.

## Messages to instructors

- They go as soon as they are ready, at any hour. An admin can turn on **Quiet hours for instructors** for a domain
  on Settings, Automation, More options; then they wait for the instructor's morning.
- Every time in a message is shown in US Pacific and India time.
- Instructors answer with the buttons, the answer page, or by replying in their channel or by email.

## In an emergency

If wrong messages are going out, tell an admin at once. An admin presses **Pause all messages** in the account menu at
the bottom of the sidebar. No instructor gets any message until an admin presses **Turn messages back on**. Nothing is
lost.

## Before you change anything big

Every change that moves classes or messages people shows a preview first. Read it. If it shows a warning, you can
still go ahead, but you write why. Your reason is saved in **Activity history**, with your name and the time.

## Who to call

- Something looks wrong in the app: the admins on the beta list (Settings, Admin shows them).
- Messages going to the wrong people: an admin, at once (see In an emergency).
- Technical problems (n8n, Supabase, Vercel): see docs/RUNBOOK.md.
