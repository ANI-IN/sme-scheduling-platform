// Release 3, M9 (decision 302): a proposed time through the app, on the Sandbox starting data. The person being asked
// for a class week sends a later start from the answer page (the same database call n8n makes for the page); Ops
// sees it on the class week, checked, and accepts it: the class moves and the instructor is confirmed. The rules
// behind each step are covered in depth by the database test 430.
import { a11y, expect, loadDemoData, noDashes, ready, sql, test } from './fixtures.ts';

test.describe.configure({ mode: 'serial' });
test.beforeAll(() => loadDemoData());
test.afterAll(() => loadDemoData());

const one = async <T>(q: string, p: unknown[] = []) => (await sql<T>(q, p))[0]!;
const monthDay = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  });

test('the person being asked proposes a later start; Ops accepts it and they are confirmed', async ({
  page,
}) => {
  // A class week of Backend that is asking someone, and their Propose another time link.
  const w = await one<{
    mw: string;
    req: string;
    who: string;
    module: string;
    cohort: string;
    start: string;
  }>(
    `select r.module_week_id mw, r.id req, i.full_name who, m.name module, c.name cohort, w.week_start_date::text start
       from public.request r join public.module_week w on w.id = r.module_week_id join public.module m on m.id = w.module_id
       join public.cohort c on c.id = w.cohort_id join public.domain d on d.id = w.domain_id
       join public.instructor i on i.id = r.instructor_id
      where d.name = 'Backend' and r.kind = 'Outreach' and r.status in ('Sent', 'Reminded') and w.first_class_at > now()
      order by w.first_class_at limit 1`,
  );
  await sql(`select private.link_for($1, 'ProposeTime')`, [w.req]);
  const r = await one<{ page: string }>(
    `with t as (select token from public.response_link where request_id = $1 and answer = 'ProposeTime'),
          k as (select c.*, row_number() over (order by c.starts_at, c.id) n,
                       (c.starts_at at time zone private.region_tz(c.region)) ls, (c.ends_at at time zone private.region_tz(c.region)) le
                  from public.class_session c where c.module_week_id = $2 and c.status = 'Planned'),
          f as (select jsonb_object_agg(x.key, x.value) form from k, lateral (values
                  ('c_' || n, to_jsonb(id::text)), ('d_' || n, to_jsonb(to_char(ls, 'YYYY-MM-DD'))),
                  ('s_' || n, to_jsonb(to_char(ls + case when n = 1 then interval '1 hour' else interval '0' end, 'HH24:MI'))),
                  ('e_' || n, to_jsonb(to_char(le + case when n = 1 then interval '1 hour' else interval '0' end, 'HH24:MI')))) x(key, value))
     select public.submit_response_page_text((select token from t), (select form from f) || jsonb_build_object('note', 'E2E: an hour later suits me')) page`,
    [w.req, w.mw],
  );
  expect(r.page).toContain('The team checks your proposed time');

  await page.goto('/classes');
  await ready(page);
  await page.getByRole('combobox', { name: 'Cohort' }).selectOption({ label: w.cohort });
  await ready(page);
  await page
    .getByRole('button', { name: `Open ${w.module}, week of ${monthDay(w.start)}`, exact: true })
    .click();
  const drawer = page.getByRole('dialog', { name: new RegExp(`^${w.module}: week of`) });
  await expect(drawer).toBeVisible();
  await ready(page);
  await expect(drawer.getByRole('heading', { name: 'Proposed time' })).toBeVisible();
  await expect(drawer.getByText(`Their note: E2E: an hour later suits me`)).toBeVisible();
  await expect(drawer.getByRole('list', { name: 'Proposed times' }).locator('li')).toHaveCount(1);
  await a11y(page, 'proposed time on the class week');
  await noDashes(page, 'proposed time on the class week');
  await drawer.getByRole('button', { name: 'Accept proposed time' }).click();
  const anyway = page.getByRole('button', { name: 'Accept anyway' });
  if (await anyway.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await page
      .getByRole('dialog')
      .filter({ has: anyway })
      .getByLabel(/^Reason/)
      .fill('E2E: agreed');
    await anyway.click();
  }
  await expect(page.getByText('Proposed time accepted: the instructor is confirmed')).toBeVisible({
    timeout: 20_000,
  });
  const after = await one<{ booked: string | null; status: string; moved: boolean }>(
    `select (select i.full_name from public.booking b join public.instructor i on i.id = b.instructor_id
              where b.module_week_id = $1 and b.status = 'Active') booked,
            (select status from public.time_proposal where module_week_id = $1 order by created_at desc limit 1) status,
            exists (select 1 from public.class_session where module_week_id = $1 and previous_starts_at is not null) moved`,
    [w.mw],
  );
  expect(after).toEqual({ booked: w.who, status: 'Accepted', moved: true });
  await expect(drawer.getByText('Moved', { exact: true }).first()).toBeVisible();
});
