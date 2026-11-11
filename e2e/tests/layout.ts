// Layout checks run on every page, drawer and dialog at every screen width (Release 2 Milestone E):
// nothing scrolls sideways, nothing spills out of its box or off the screen, and no two controls
// or labels sit on top of each other.
import type { Page } from '@playwright/test';
import { expect } from './fixtures.ts';

export type LayoutProblem = { kind: 'overflow' | 'offscreen' | 'overlap'; what: string };

/**
 * Looks at what a person can see: the top layer (an open drawer, dialog or menu) when there is one,
 * otherwise the page. Elements inside a scroll box are only checked against that box.
 */
export async function layoutProblems(page: Page): Promise<LayoutProblem[]> {
  return page.evaluate(() => {
    const out: { kind: 'overflow' | 'offscreen' | 'overlap'; what: string }[] = [];
    const vw = document.documentElement.clientWidth;
    const layers = [
      ...document.querySelectorAll<HTMLElement>(
        '[role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"]',
      ),
    ].filter((l) => l.checkVisibility?.());
    const root: HTMLElement = layers[layers.length - 1] ?? document.body;

    const describe = (el: Element) => {
      const h = el as HTMLElement;
      const name =
        h.getAttribute('aria-label') ||
        h.innerText?.trim().split('\n')[0]?.slice(0, 50) ||
        h.getAttribute('placeholder') ||
        h.getAttribute('title') ||
        '';
      return `${el.tagName.toLowerCase()}${name ? ` "${name}"` : ''}`;
    };
    const visible = (el: Element) => {
      const h = el as HTMLElement;
      if (!h.checkVisibility?.({ checkOpacity: true, checkVisibilityCSS: true })) return false;
      if (h.closest('.sr-only, [aria-hidden="true"], [data-layout-skip]')) return false;
      const r = h.getBoundingClientRect();
      return r.width > 1 && r.height > 1;
    };
    /** The nearest box that clips or scrolls its content (tables, code, drawers). */
    const clipBox = (el: Element): Element | null => {
      for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
        const s = getComputedStyle(p);
        if (/(auto|scroll|hidden|clip)/.test(s.overflowX + s.overflow)) return p;
      }
      return null;
    };

    // 1. Text and controls that spill out of their own box without a way to scroll to them.
    const boxes = root.querySelectorAll<HTMLElement>(
      'button, a, label, h1, h2, h3, th, td, p, [role="tab"], select, span.inline-flex',
    );
    for (const el of boxes) {
      if (!visible(el)) continue;
      const s = getComputedStyle(el);
      if (/(auto|scroll)/.test(s.overflowX)) continue;
      // Text that is cut on purpose ends with "…" (truncate); that is fine.
      if (s.textOverflow === 'ellipsis') continue;
      if (el.scrollWidth > el.clientWidth + 2 && el.clientWidth > 0 && s.overflowX !== 'visible') {
        out.push({ kind: 'overflow', what: `${describe(el)} is cut off` });
      }
    }

    // 2. Anything off the right edge of the screen that cannot be scrolled to.
    for (const el of root.querySelectorAll<HTMLElement>(
      'button, a, input, select, textarea, h1, h2, p, label',
    )) {
      if (!visible(el)) continue;
      const clip = clipBox(el);
      const r = el.getBoundingClientRect();
      if (clip) {
        const s = getComputedStyle(clip);
        if (/(auto|scroll)/.test(s.overflowX + s.overflow)) continue;
        const c = clip.getBoundingClientRect();
        if (r.right > c.right + 2 && r.left < c.right) {
          out.push({ kind: 'offscreen', what: `${describe(el)} sticks out of its box` });
        }
        continue;
      }
      if (r.right > vw + 2)
        out.push({ kind: 'offscreen', what: `${describe(el)} goes off the screen` });
    }

    // 3. Controls on top of each other. Only controls that are not nested in each other, and only
    // in the same scroll box (a sticky header over a scrolled list is fine).
    const controls = [
      ...root.querySelectorAll<HTMLElement>(
        'button, a[href], input:not([type="hidden"]), select, textarea, [role="tab"], [role="switch"], [role="checkbox"]',
      ),
    ].filter(visible);
    // A link that wraps onto two lines has one box per line; its outer box would wrongly cover the
    // words between them, so each line box is compared on its own.
    const rects = controls.map((c) => ({
      el: c,
      r: c.getBoundingClientRect(),
      lines: [...c.getClientRects()].filter((x) => x.width > 1 && x.height > 1),
      clip: clipBox(c),
    }));
    const hit = (x: DOMRect, y: DOMRect) =>
      Math.min(x.right, y.right) - Math.max(x.left, y.left) > 4 &&
      Math.min(x.bottom, y.bottom) - Math.max(x.top, y.top) > 4;
    for (let i = 0; i < rects.length; i++) {
      for (let j = i + 1; j < rects.length; j++) {
        const a = rects[i]!;
        const b = rects[j]!;
        if (a.el.contains(b.el) || b.el.contains(a.el)) continue;
        if (a.clip !== b.clip) continue;
        // A label wrapping its own checkbox or input counts as one control.
        if (a.el.closest('label') && a.el.closest('label') === b.el.closest('label')) continue;
        for (const x of a.lines) {
          const y = b.lines.find((l) => hit(x, l));
          if (!y) continue;
          // Only a real problem when the top control hides the other one at its centre.
          const cx = (Math.max(x.left, y.left) + Math.min(x.right, y.right)) / 2;
          const cy = (Math.max(x.top, y.top) + Math.min(x.bottom, y.bottom)) / 2;
          const top = document.elementFromPoint(cx, cy);
          if (top && (a.el.contains(top) || b.el.contains(top))) {
            out.push({ kind: 'overlap', what: `${describe(a.el)} overlaps ${describe(b.el)}` });
            break;
          }
        }
      }
    }
    return out.slice(0, 20);
  });
}

/** Every layout check at once; problems are listed together so one run shows them all. */
export async function layoutOk(page: Page, label: string) {
  const over = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect.soft(over, `${label} scrolls sideways by ${over}px`).toBeLessThanOrEqual(1);
  const problems = await layoutProblems(page);
  expect
    .soft(
      problems.map((p) => `${p.kind}: ${p.what}`),
      `${label}: layout problems at ${page.viewportSize()?.width}px`,
    )
    .toEqual([]);
}
