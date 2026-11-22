title: Standard schedules
summary: The usual plan for a cohort: plan several cohorts from it at once, see what is Custom, reset and update.
order: 6.2
---

A **standard schedule** is the usual plan for a cohort of your domain: which modules it takes, in which order, the class times of each module, and any break weeks. A domain can have more than one, for example one per track. Every new cohort planned from it gets the same class weeks, in its own time zone.

## Create a standard schedule

1. Open [Standard schedules](/setup/standards) and press **Add standard schedule**.
2. Give it a **Name**, for example SWEs. Notes are optional.
3. Under **Modules in order**, choose a module and press **Add module**. Add the others the same way. Drag a module to change its place.
4. Under **Breaks**, press **Add a break** for a week without classes. Choose the module it comes after and how many weeks (1 to 8).
5. Press **Add standard schedule**. It opens so you can finish it.
6. Under **Class times**, each module shows the class times it uses. A module uses its own class times (from its module page) unless you add class times here, which only this standard uses.

## Plan cohorts from a standard

1. On [Standard schedules](/setup/standards) press **Plan cohorts**, or open the standard and press **Plan cohorts** there. You can also start from **Plan classes** on [Upcoming classes](/classes) when you choose a new cohort, or from the cohorts of a domain on [Domains](/setup/domains).
2. Choose the **Standard schedule**.
3. Give the new cohort a **Name**, a **Start date** (the day of its first class) and a **Region** (US or India).
4. To plan several cohorts at once, press **Add another cohort** for each one. Each can start on its own date and in its own region.
5. Press **Show the plan**. You see every class week of every new cohort, with its classes and any warnings.
6. Anything under **Fix these before creating** must be fixed first, for example a name that is already used or a module without class times. Press **Back** to change it.
7. If a class time happens twice because the US clocks move back, choose which one you mean.
8. Press **Create**. If there are warnings, you can still go ahead and write a short reason.

## Standard and Custom

Each cohort shows how it follows its standard, on its domain's cohort list and on the standard schedule:

- **Standard: SWEs** means every class week follows the standard.
- **Custom (2 changes)** means two class weeks were changed for this cohort: their dates, times, classes or module. A class week added by hand also counts.
- **Fully custom** means the cohort was not planned from a standard.

Changing one cohort never changes another cohort on the same standard. Open a class week from [Upcoming classes](/classes) to see, under **Standard schedule**, the standard version next to what it is now.

## Reset to standard

1. To bring one class week back, open it and press **Reset to standard** under **Standard schedule**. To bring back every class week still to come of a cohort, press **Reset to standard** next to the cohort.
2. Read the preview. It lists what moves, what is added and what is cancelled.
3. Press **Reset**. If an instructor is confirmed, they are asked about a new time as usual.

A confirmed class week only comes back when its classes just move. Adding or removing a class there stays on the class week itself.

## When the standard changes

Changes to a standard reach its cohorts only when you say so.

1. Change the standard: its modules, breaks or class times.
2. In **Cohorts following it**, press **Update cohorts**.
3. Choose **All cohorts that follow it**, or only the cohorts you choose.
4. Read the preview: what changes in each class week, any new class weeks (for a module added to the standard), and **Not updated** with the reason.
5. Press **Update cohorts**. If there are warnings, write a short reason to go ahead.

Some class weeks are **Not updated** on purpose:

- **Changed for this cohort:** the class week is Custom. Use **Reset to standard** on it if you want it back.
- **An instructor is confirmed:** change the time on the class week itself, so they are asked about the new time.
- **It has already started or taken place**, or it is cancelled.

Every update and reset is saved in [Activity history](/activity).
