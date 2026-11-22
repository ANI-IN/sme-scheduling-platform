title: Breaks, cohort holidays and merges
summary: Give a cohort, or every cohort, a break of whole weeks, add a day off for one cohort, and merge cohorts.
order: 11
group: Daily work
keywords: break, program break, cohort break, holiday, cohort holiday, day off, Diwali, merge cohorts, combined cohort, undo merge, remove break, keep with a reason
---

You find breaks and cohort holidays in two places:

- On the [Schedule board](/board), under **Cohort actions** in a cohort's header, or by selecting class weeks and pressing **Add a break**.
- On [Domains](/setup/domains): open the domain and go to **Breaks and cohort holidays**.

## Add a break for a cohort

A break moves every class week of a cohort from its first day on back by whole weeks. Each class keeps its local time, and the cohort's later breaks move with it.

1. Press **Add a break**.
2. Fill in **What is the break for?**, for example Diwali. Choose the **First day**, the **Length** and the **Cohorts**.
3. Check the preview: what moves in each cohort, every class with its old and new time, and who is confirmed or being asked.
4. Press **Add break**.

Nothing is saved until you press **Add break**. Each confirmed instructor gets one message with all their class weeks that moved, and answers **Still works** or **Doesn't work** for each one. Someone being asked gets the request again with the new times.

## Add a program break

A program break gives every cohort of the domain the same break. On Domains, press **Add a program break**. It works like a cohort break, shows as one row across the Schedule board, and **Remove** takes it away from every cohort.

## What can stop a break

- It starts in the past, or inside a class week that has started.
- A class week starts before the first day and has classes after it. Start the break on that class week's first day, or after it.
- It overlaps another break of the same cohort.
- A confirmed instructor can't teach the new dates, because they would be in two classes at once or they are unavailable then. These are listed under **Instructors who can't teach the new dates**. Tick the box next to them to release them from that class week and ask the next instructor, or choose other dates.

Anything unusual after the move, for example a class on a holiday or an instructor with a full day, is listed under **New problems after the move**. To go ahead, say why. Your reason is saved in Activity history.

## Remove a break

On Domains, press **Remove** next to the break, then **Remove break**. Every class week after it moves back by the break, with the same preview and checks. A break that has started can't be removed this way: change the class weeks one by one instead.

## Add a cohort holiday

A cohort holiday is a day off for one cohort only. Holidays for a whole domain or region are under **Holidays** in the domain's panel.

1. Press **Add a cohort holiday**, choose the cohort and the day, and give it a name, for example Founders day.
2. Press **Add holiday**. The app lists the classes of that cohort on that day.
3. Each one shows on its class week. Change its time, cancel it, or press **Keep with a reason** and then **Keep class**. Your reason is saved in Activity history.

Planning a class on a cohort holiday, or during a break of its cohort, gives a warning. On the board, such a class shows **Cohort holiday** or **During a break**.

## Merge cohorts

From a date, two or more cohorts can continue as one combined cohort. Before that date they stay as they are, and each shows **Merged into** with the date.

1. On Domains under **Cohorts and regions**, press **Merge cohorts**. Or use **Merge with another cohort** under **Cohort actions** on the board.
2. Under **Cohorts to merge**, tick the cohorts.
3. Fill in the **Name of the combined cohort**, the **Merge date** (the first day of a class week, after every cohort has started) and its **Time zone**. Choose whose **Module sequence of** and whose **Instructor order of** it follows.
4. Check **Class weeks from the merge date**. Each one either **Moves to the combined cohort** or is cancelled, because the chosen sequence already has that module.
5. Under **Merge check**, read what does not line up. When both cohorts have a confirmed instructor for the same module, the chosen cohort's instructor stays and the other gets a release note. Tick **Keep this cohort's class week and instructor instead** to choose the other. A class week with no match stays unless you tick **Cancel this class week**.
6. Press **Merge cohorts**, and say why if there are warnings.

**Undo merge** next to a merged cohort is there until the merge date. Class weeks go back to their cohorts and cancelled ones are planned again. An instructor released by the merge is not brought back: that class week asks its instructor order.
