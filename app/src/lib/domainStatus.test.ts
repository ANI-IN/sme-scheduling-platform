import { describe, expect, it } from 'vitest';
import { changesStatusKey, statusConfirm } from './domainStatus';

const fx = { open_requests: 3, waiting_messages: 2, waiting_requests: 3 };
const say = (from: string, to: string) => statusConfirm('Backend', from, to, fx);

describe('statusConfirm (review finding R9)', () => {
  it('asks before every change to Draft, naming what is withdrawn and cancelled', () => {
    for (const from of ['Live', 'Test', 'Paused']) {
      const c = say(from, 'Draft')!;
      expect(c.danger).toBe(true);
      expect(c.body).toContain('3 open requests are withdrawn');
      expect(c.body).toContain('2 messages waiting to be sent are cancelled');
    }
  });
  it('asks before leaving Live, saying what happens to open requests', () => {
    expect(say('Live', 'Paused')!.body).toContain('3 open requests keep their place');
    expect(say('Live', 'Test')!.body).toContain('testing channel');
  });
  it('asks before going live and before leaving testing', () => {
    expect(say('Draft', 'Live')!.title).toBe('Go live with Backend?');
    expect(say('Test', 'Paused')!.title).toBe('Stop testing Backend?');
  });
  it('asks nothing when nothing is at stake', () => {
    expect(say('Draft', 'Test')).toBeNull();
    expect(say('Paused', 'Test')).toBeNull();
    expect(say('Live', 'Live')).toBeNull();
  });
  it('counts one request in the singular', () => {
    expect(
      statusConfirm('Backend', 'Live', 'Draft', { ...fx, open_requests: 1, waiting_messages: 1 })!
        .body,
    ).toContain('1 open request is withdrawn and 1 message waiting to be sent is cancelled');
  });
});

describe('changesStatusKey: keys that would change a closed status list', () => {
  it('stops arrows and letters, keeps keys that open it or move on', () => {
    for (const key of ['ArrowDown', 'ArrowUp', 'Home', 'End', 'PageDown', 'l', 'D'])
      expect(changesStatusKey({ key, altKey: false }), key).toBe(true);
    for (const key of ['Enter', ' ', 'Tab', 'Escape'])
      expect(changesStatusKey({ key, altKey: false }), key).toBe(false);
    expect(changesStatusKey({ key: 'ArrowDown', altKey: true })).toBe(false);
  });
});
