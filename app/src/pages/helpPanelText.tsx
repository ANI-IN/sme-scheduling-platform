// The words of the Legend and help panel's second and third tabs (decision 344), for the Schedule board and Upcoming
// classes. Plain steps for the operations team; the wording scan checks them like every page.

const H = ({ children }: { children: string }) => (
  <h3 className="mt-4 mb-1 text-sm font-semibold first:mt-0">{children}</h3>
);
const Item = ({ term, children }: { term: string; children: string }) => (
  <div>
    <dt className="font-medium">{term}</dt>
    <dd className="text-muted-foreground">{children}</dd>
  </div>
);

export function BoardReading() {
  return (
    <>
      <H>Rows, columns and cells</H>
      <p>
        By cohort, each column is a cohort and each row is a week, starting this week. Each cell is
        one class week of that cohort: a module and its classes that week.
      </p>
      <p>
        A cell shows the module, the status (for example Confirmed or Waiting for an answer), the
        instructor (or who is planned, and the day asking starts), and up to three badges for
        anything unusual. +2 means two more badges inside. Hold the pointer on a cell, or move to it
        with the keyboard, to read what its status and badges mean.
      </p>
      <H>Needs a decision</H>
      <p>
        Above the board, Needs a decision lists the class weeks where you must choose something:
        nobody left to ask, a clash, a proposed time, a class on a holiday. Open one to see the
        problem and its fixes.
      </p>
      <H>What to do for each problem</H>
      <dl className="space-y-2">
        <Item term="Needs instructor">
          Phone people, then open the class week and press Assign and confirm instructor, or add
          instructors to the module's order.
        </Item>
        <Item term="Clash">
          The instructor teaches somewhere else at the same time. Move a class, or ask someone else.
        </Item>
        <Item term="Proposed time">
          Open the class week, look at the new time, then Accept proposed time or Reject.
        </Item>
        <Item term="Holiday or Cohort holiday">
          Move the class, cancel it, or keep it and write why.
        </Item>
        <Item term="Message failed or Check needed">
          Open the task on Home and do what it says, then Send again or It arrived, mark as sent.
        </Item>
        <Item term="Help request open">Open the help request and answer the instructor.</Item>
      </dl>
      <H>How special cases look</H>
      <dl className="space-y-2">
        <Item term="Sooner class first">
          When one instructor is wanted for two classes at the same time, the sooner class asks them
          first, and the later class week asks its next instructor. The later cell shows Sooner
          class first.
        </Item>
        <Item term="Breaks">
          A cohort's break shows as a Break row in its column, with the reason. A program break is
          one row across every cohort. The class weeks after it move back.
        </Item>
        <Item term="Shared classes">
          Class weeks of two cohorts taught together show Shared class. The guest takes its
          instructor from the host, and is not asked on its own.
        </Item>
        <Item term="Cohort holidays">
          A class on a holiday of its cohort shows Cohort holiday until you move it, cancel it, or
          keep it with a reason.
        </Item>
      </dl>
    </>
  );
}

export function BoardControls() {
  return (
    <dl className="space-y-2">
      <Item term="By cohort">One column per cohort, one row per week. The usual view.</Item>
      <Item term="By instructor">
        One column per instructor, to see who teaches what and spot a busy week.
      </Item>
      <Item term="List">Every class week in one list. Easiest on a phone.</Item>
      <Item term="Earlier, This week, Later">
        Move the weeks shown back, to this week, or forward.
      </Item>
      <Item term="Week range">How many weeks the board shows at once.</Item>
      <Item term="Only problems">Shows only the class weeks that need something from you.</Item>
      <Item term="Compare to standard">
        Marks class weeks that are not in their cohort's standard schedule, or changed from it.
      </Item>
      <Item term="Filters">
        Cohort, Standard schedule, Module, Region, Status, Instructor and Badge narrow the board.
        They are remembered for you on this browser.
      </Item>
      <Item term="Select class weeks">
        Tick several cells, then use one action for all of them: Start asking now, Move by weeks,
        Add a break, Share a class or Cancel, each with a preview first.
      </Item>
      <Item term="Download as spreadsheet">Saves what the board shows now as a spreadsheet.</Item>
      <Item term="Legend and help">Opens and closes this panel. Escape closes it too.</Item>
    </dl>
  );
}

export function ClassesReading() {
  return (
    <>
      <H>The list</H>
      <p>
        Each row is one class week: the module, the cohort, its classes with their times, its
        status, and who teaches it (or who is planned, and the day asking starts). Past and
        cancelled class weeks are hidden unless you show them.
      </p>
      <H>Statuses</H>
      <p>
        The status says where asking stands: Not asked yet, Waiting for an answer, Confirmed, Needs
        instructor and so on. Open the Legend tab for every status and badge in one line each.
      </p>
      <H>Opening a class week</H>
      <p>
        Select a row to open its side panel: the classes, who was asked and what they said, the
        messages, and every action for that class week.
      </p>
      <H>What to do for a problem</H>
      <p>
        Needs instructor: phone people, then Assign and confirm instructor. A proposed time: Accept
        proposed time or Reject. A failed message or Check needed: follow the task on Home.
      </p>
    </>
  );
}

export function ClassesControls() {
  return (
    <dl className="space-y-2">
      <Item term="Plan classes">Creates class weeks from each module's class times.</Item>
      <Item term="Add one class">Adds a single class, for example an extra session.</Item>
      <Item term="Search classes">Finds class weeks by module, cohort or instructor.</Item>
      <Item term="Filters">
        Cohort, Module, Region, Status and Instructor narrow the list, and are remembered for you.
      </Item>
      <Item term="Show past and cancelled">Shows class weeks that are over or cancelled.</Item>
      <Item term="Select class weeks">
        Tick rows, then Start asking now, Choose who to ask, Move by weeks or Cancel classes for all
        of them.
      </Item>
      <Item term="Download as spreadsheet">Saves the list as a spreadsheet.</Item>
      <Item term="Legend and help">Opens and closes this panel. Escape closes it too.</Item>
    </dl>
  );
}
