title: US and India classes
summary: Each cohort is taught in US Pacific time or India time. How times are shown, the clock changes, and clashes.
order: 19
group: Reference
keywords: US, India, region, time zone, PST, PDT, IST, Pacific, daylight saving, clock change, holiday, clash, other time zone
---

Every cohort has a **region**: **US** or **India**. The region decides the time zone of its classes.

- **US** classes use US Pacific time. It is **PST** in winter and **PDT** in summer, when the clocks move one hour forward.
- **India** classes use India time (**IST**). It never changes.

A **time zone** is the local clock time of a place. The app saves every class at one exact moment, so the same class shows the right time everywhere.

## How times are shown

![Upcoming classes with the Region and Status filters](/help/classes-regions.png)

- Every class time ends with its zone, for example "Sun, Jan 24, 9:00 AM to 1:00 PM PST".
- A US class also shows the India time underneath in smaller text, because the team works in India.
- The **US** or **India** badge next to a class shows its region.
- On [Upcoming classes](/classes), use the **Region** filter (1) to see only US or only India classes, and the **Status** filter (2) to see only classes with a given status. Each class shows its time in its own time zone (3).
- On [Instructor requests](/requests), each class week shows its cohort, region and first class time, with **Module**, **Cohort** and **Region** filters.
- Messages to instructors show the class in its own time zone.

## Choose the region of a cohort

1. When you plan a **New cohort**, choose its **Region**. Class times in the plan are then in that time zone.
2. To change the region of a cohort later, open [Domains](/setup/domains) and find **Cohorts and regions**. Classes already planned keep their time; only new classes use the new region.

## One class in the other time zone

1. Open the class week from the [Schedule board](/board) or [Upcoming classes](/classes).
2. Under the class, open **More options for this class** and choose the time zone.
3. Check the date and times, then press **Change time**.

When you add one class, the same choice is under **More options** in the dialog.

## When the US clocks change

- On the night the clocks move forward (in March), times between 2:00 AM and 3:00 AM do not exist. The app blocks them and asks for another time.
- On the night the clocks move back (in November), times between 1:00 AM and 2:00 AM happen twice. The app asks which one you mean: the first (PDT) or the second (PST).
- A class at 9:00 AM stays at 9:00 AM local time after a clock change. Its India time moves by one hour.

## Holidays

Each holiday is for **US** classes, **India** classes, or both. A US holiday only warns about US classes, and an India holiday only about India classes.

1. Open [Domains](/setup/domains), open the domain and go to **Holidays**.
2. Choose the **Date**, give it a **Name** and choose the **Region**.
3. Press **Add holiday**.

A day off for one cohort only is a cohort holiday. See [Breaks, cohort holidays and merges](/help/breaks-and-holidays).

## Clashes

An instructor can never teach two classes at the same moment, in any cohort, domain or region. The app compares the exact moments, so a Saturday 7:30 PM PST class and a Sunday 9:00 AM IST class are the same time.

- When you assign someone who is busy, the app says which class they are teaching, its cohort and both local times.
- In the instructor order, a busy instructor is skipped and the reason is shown.
- Moving a class onto another class of the same instructor is blocked.

How to fix a clash is in [Fixing problems on a class week](/help/fixing-problems).
