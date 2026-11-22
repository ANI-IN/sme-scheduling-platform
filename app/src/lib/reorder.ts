// What a screen reader hears while a list of instructors is reordered with the keyboard: names and
// places ("Maya moved to Backup 2"), never the ids the drag library works with.
import type { Announcements, ScreenReaderInstructions } from '@dnd-kit/core';

export function reorderA11y(
  order: string[],
  nameOf: (id: string) => string,
  placeOf: (index: number) => string,
  /** What is being moved, for the instructions ("an instructor", "a module"). */
  what = 'an instructor',
): { announcements: Announcements; screenReaderInstructions: ScreenReaderInstructions } {
  const place = (id: string | number | undefined) =>
    id === undefined ? '' : placeOf(order.indexOf(String(id)));
  const name = (id: string | number) => nameOf(String(id));
  return {
    screenReaderInstructions: {
      draggable:
        what === 'an instructor'
          ? 'To move an instructor, press Space, then the up and down arrow keys. Press Space again to drop them there, or Escape to leave them where they were.'
          : `To move ${what}, press Space, then the up and down arrow keys. Press Space again to drop it there, or Escape to leave it where it was.`,
    },
    announcements: {
      onDragStart: ({ active }) => `Picked up ${name(active.id)}, ${place(active.id)}.`,
      onDragOver: ({ active, over }) =>
        over
          ? `${name(active.id)} is over ${place(over.id)}.`
          : `${name(active.id)} is not over a place.`,
      onDragEnd: ({ active, over }) =>
        over ? `${name(active.id)} moved to ${place(over.id)}.` : `${name(active.id)} was dropped.`,
      onDragCancel: ({ active }) => `${name(active.id)} stays at ${place(active.id)}.`,
    },
  };
}
