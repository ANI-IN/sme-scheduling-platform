title: Setting up a module
summary: Class times, instructor order, owners and operations team, step by step, and changing a module later.
order: 4
group: Setup
keywords: module, add module, class times, rotation, owner, operations team, who we ask next, materials, draft, live, ready, not in use
---

A module is something your domain teaches, for example Concurrency. The app plans class weeks from the module's class times and asks instructors in the module's instructor order.

![The steps of adding a module](/help/module-new.png)

## Add a module

1. Open [Modules](/setup/modules) and press **Add module**.
2. **Module details:** enter the name and its **Order in the rotation** (1 is the first module). Press **Save and continue**. Until you finish, the module is saved as a **Draft**, so it is not planned and nobody is asked yet.
3. **Class times:** add each class of one class week. Press **Add class**, choose the **Class type**, the day (counted from the first class of the class week, on any weekday), **Starts (local time)** and **Length in minutes**. For example a live class on the first day at 9:00 AM for 240 minutes, and an assignment review 4 days after the first day at 6:00 PM for 120 minutes.
4. **Instructor order:** choose instructors and drag them into order. The first is the **Primary instructor**, then **Backup 1**, **Backup 2** and so on. Use **Add new instructor** if someone is missing.
5. **Owners and operations team:** press **Add an owner** and choose at least one. The operations team comes from the domain.
6. **Review and save:** missing items are marked under **Before you save**. Press **Save and make live**, or **Save as draft** to finish later.

Use **Back** and **Continue** to move between the steps.

## Change a module later

Open the module from [Modules](/setup/modules). Each part has its own tab: **Details**, **Class times**, **Instructor order**, **Owners**, **Operations team** and **Who we ask next**.

- To give one cohort different class times or a different instructor order, open the tab and choose the cohort under **For**. **Every cohort (the module default)** is the usual one, and a cohort with its own shows **(has its own)**.
- To give the module its own operations team, use the **Operations team** tab. Leave it empty to use the domain's default operations team.
- **Who we ask next** shows, for each upcoming class week without an instructor, who the app would ask next.
- Owners are tagged when requests start, when an instructor confirms, and when something needs their decision. A module needs at least one owner before requests can start.

Classes already planned keep their times when you change the class times. Cohorts on a standard schedule change only when you press **Update cohorts** there. See [Standard schedules](/help/standard-schedules).

## The Modules list

The list shows each module's order, status, owners, operations team and instructors. A module's status is:

- **Draft:** being set up. It is skipped when planning and nobody is asked.
- **Live:** instructors are asked.
- **Archived:** kept for the record, shown only when you tick **Show archived modules**.

A module is **Ready** when it has class times, an owner and at least 1 instructor in use in its instructor order. The number of instructors is a setting on [Automation](/settings/automation), under **Instructors per module**. Otherwise **Needs attention** says what is missing, for example **No class times**, **No owner** or **Needs 1 instructor, has 0**.

The instructor order itself is explained in [Instructors and the instructor order](/help/instructors).
