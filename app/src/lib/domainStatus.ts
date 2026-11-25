// Review finding R9 (decision 349): every change away from Live and every change to Draft is confirmed first, naming
// what happens, and the status list never changes just because an arrow key was pressed on it.
export type StatusEffects = {
  open_requests: number;
  waiting_messages: number;
  waiting_requests: number;
};

export type StatusConfirm = {
  title: string;
  body: string;
  confirmLabel: string;
  danger: boolean;
};

const some = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

export function statusConfirm(
  name: string,
  from: string,
  to: string,
  fx: StatusEffects,
): StatusConfirm | null {
  if (from === to) return null;
  if (to === 'Live')
    return {
      title: `Go live with ${name}?`,
      body: 'Real instructors will be contacted from the next automatic check.',
      confirmLabel: 'Go live',
      danger: true,
    };
  if (to === 'Draft') {
    const requests = some(fx.open_requests, 'open request is', 'open requests are');
    const messages = some(
      fx.waiting_messages,
      'message waiting to be sent is',
      'messages waiting to be sent are',
    );
    return {
      title: `Move ${name} back to Draft?`,
      body: `${requests} withdrawn and ${messages} cancelled. Nothing is sent to instructors while it is a draft.`,
      confirmLabel: 'Move to Draft',
      danger: true,
    };
  }
  const open = some(fx.waiting_requests, 'open request', 'open requests');
  if (from === 'Live' && to === 'Test')
    return {
      title: `Turn on testing for ${name}?`,
      body: `Every message for ${name}, including its ${open}, goes to the testing channel and testing email instead of the instructors.`,
      confirmLabel: 'Turn on testing',
      danger: true,
    };
  if (from === 'Live')
    return {
      title: `Pause ${name}?`,
      body: `Messages to instructors wait until you resume it. The ${open} keep their place, and the time paused is added to their answer time.`,
      confirmLabel: 'Pause',
      danger: false,
    };
  if (from === 'Test')
    return {
      title: `Stop testing ${name}?`,
      body: `${name} will be paused. Messages stop going to the testing channel.`,
      confirmLabel: 'Set to Paused',
      danger: false,
    };
  return null;
}

/** On a closed list, arrows, Home, End and letters change the value in some browsers. */
export function changesStatusKey(e: { key: string; altKey: boolean }): boolean {
  if (e.altKey) return false;
  const moves = [
    'ArrowUp',
    'ArrowDown',
    'ArrowLeft',
    'ArrowRight',
    'Home',
    'End',
    'PageUp',
    'PageDown',
  ];
  return moves.includes(e.key) || (e.key.length === 1 && e.key !== ' ');
}
