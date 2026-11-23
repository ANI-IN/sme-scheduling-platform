title: Instructors and the instructor order
summary: Add instructors and test instructors, choose their Discord channels, set the order per module, change who is asked for one class week, and add dates they cannot teach.
order: 7
group: Setup
keywords: instructor, add instructor, test instructor, Discord username, channel, contact check, instructor order, primary, backup, chosen list, ask a specific person, unavailable, dates they cannot teach, availability, not in use, instructor requests
---

Each real person is added once and shared by every domain. The app never books one instructor for two classes at the same time, in any domain or cohort.

## Add an instructor

![The Instructors page](/help/instructors-list.png)

1. Open [Instructors](/setup/instructors) and press **Add instructor**.
2. Under **Basic details**, enter the **Full name** and **Email**. Add **Other emails** they use, so their replies are matched to them.
3. If they prefer a limit, enter **Classes a month (optional)**. The app warns you before asking them for more, but you can still ask.
4. Under **Discord**, type their **Discord username**, for example maya.k, without @.
5. Press **Add instructor**, or **Save and add another**. The app finds their Discord account by itself and shows **Discord found**.

If it shows **Not found on Discord**, check the spelling and that they joined the server, then press **Check Discord**. An instructor with the same email or Discord username is never added twice: the app points you to the existing record.

## Choose their channel in each domain

![An instructor's Discord username and channel](/help/instructor-discord.png)

1. Open the instructor again after you add them. Their Discord username must be found first (**Discord found**).
2. Under **Their channel in each domain**, do one of these:
   - choose their own channel from the list (type part of the name to find it);
   - paste the channel's link (in Discord, right click the channel and choose **Copy Link**) or its ID, then press **Check and use**;
   - press **Use #name** next to **Suggested**: the app suggests the channel in the domain's server named after them, for example #victor.
3. The app checks the channel in Discord, usually in a few seconds: the server is approved for the domain, the bot can post there (View Channels, Send Messages, Embed Links, Read Message History), and the instructor is in the server and can see the channel.
4. If all is right, the channel is saved and shows **Channel ready**. If not, it is not saved, and the app says exactly what to fix, for example **Give Victor Palmer access to #victor**. Fix it in Discord, then choose the channel again.

Nobody needs to create a channel or an invite in the app. From then on every request, reminder and confirmation for that domain goes to their channel, tagging them, and always by email too. Without a channel in a domain, they get a direct message on Discord instead. A channel chosen before these checks shows **Not checked yet** with a button to check it.

## The welcome message

When you add an instructor, they get a short welcome by email. When their channel in a domain is first ready, they get one there on Discord too, tagging them. It says they are set up to receive class requests from SME Scheduling, and that they answer with the buttons in each message. It is never sent twice to the same person for the same domain and channel. [Activity history](/activity) shows **Welcome message sent**, or that it was blocked and why. You can change the text on [Message templates](/settings/messages) and switch it off on [Automation](/settings/automation).

## Check their contact details (optional)

A contact check is optional. Instructors you add are asked whether or not their contact details are checked. Use it when you want to be sure their Discord and email work.

1. Open the instructor and go to **Contact check**.
2. Press **Send contact check**. They get a short message on Discord and by email with one button.
3. When they press it, the list shows **Contact checked**.

If you checked their details another way, for example on a call, press **Mark as checked**. Saving a new email or Discord username clears the check. You can send a new one if you like.

## Test instructors

Tick **Test instructor** for a record that is only for trying things out. Test instructors are never booked in a live domain. Several test instructors can share one Discord username and use plus email addresses, for example name+1@company.com, so one person can play several instructors. While the beta setting is on under Settings, Admin, only test instructors and signed in colleagues get messages.

Tick **Show test instructors** on the Instructors page to see them.

## Dates they cannot teach

1. Open the instructor and go to **Availability**.
2. Under **Dates they cannot teach**, choose the **First day** and **Last day**, and add a **Reason (optional)**.
3. Press **Add dates**.

The app skips them for classes on those days. A confirmed class on those days shows **Unavailable** on the Schedule board.

## The instructor order of a module

The instructor order decides who is asked first for a module. The **Primary instructor** is asked first, then **Backup 1**, **Backup 2** and so on, one at a time.

![A module's instructor order](/help/instructor-order.png)

1. Open the module from [Modules](/setup/modules) and go to the **Instructor order** tab.
2. To give one cohort its own order, choose the cohort under **For**.
3. Choose someone under **Instructor to add** and press **Add**. Drag people to change the order.
4. Press **Review and save**. The window shows, for each class week without an instructor, who is **Asked next now** and **After saving**.
5. Press **Save order**. **Undo changes** puts the order back.

Changes only affect the next person asked, never a request already sent. Confirmed class weeks stay as they are. The **Who we ask next** tab shows who the app would ask next for each class week, with the reason someone is skipped.

## Change who is asked for one class week

On [Instructor requests](/requests), each class week still looking for an instructor shows who is being asked, when it moves on and who is next. Select a card at the top to show only those class weeks.

![Instructor requests](/help/instructor-requests.png)

- **Start asking now** asks before the usual day.
- **Ask the next instructor** withdraws the current request politely and asks the next one.
- **More** opens: **Change the order for this class week**, **Ask a specific person**, **Assign and confirm instructor**, **Record a phone or chat confirmation**, and **Pause requests**.

With **Change the order for this class week**, tick instructors in the order they should be asked and choose what happens **When the list runs out**: **Stop and tell me** or **Carry on with the instructor order**. Press **Start asking**. The class week then shows **Chosen list** instead of **Instructor order**.

With **Ask a specific person**, choose them and press **Ask now**. If someone is being asked right now, choose **Withdraw and ask now** or **Ask after their answer**. If they say no, the usual instructor order continues.

## When someone stops teaching

Open the instructor and press **Stop using**. They are not asked again. If they have confirmed classes, you choose for each one **Keep, they still teach it** or **Release and find someone else**. **Start using again** brings them back, and **Archive** also hides them from the lists.
