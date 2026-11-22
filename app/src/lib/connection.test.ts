import { describe, expect, it } from 'vitest';
import { channelStatus, fixFor } from './connection';

describe('channelStatus', () => {
  it('is Ready, not broken, when set up and nothing was sent', () => {
    expect(channelStatus(true, null, null)).toBe('ready');
  });
  it('is Not set up when a step is missing', () => {
    expect(channelStatus(false, null, null)).toBe('off');
  });
  it('is Working after a message went out, even after an older failure', () => {
    expect(channelStatus(true, '2026-11-22T10:00:00Z', '2026-11-22T09:00:00Z')).toBe('working');
  });
  it('is a Problem only when the last attempt failed after the last success', () => {
    expect(channelStatus(true, '2026-11-22T10:00:00Z', '2026-11-22T11:00:00Z')).toBe('problem');
    expect(channelStatus(true, null, '2026-11-22T11:00:00Z')).toBe('problem');
  });
});

describe('fixFor', () => {
  it('names the fix for a deleted channel, a missing permission and refused direct messages', () => {
    expect(fixFor('Discord', 'Unknown Channel (10003)')).toMatch(/channel was deleted/);
    expect(fixFor('Discord', 'Missing Permissions')).toMatch(/not allowed to post/);
    expect(fixFor('Discord', 'Cannot send messages to this user')).toMatch(/direct messages/);
  });
  it('always suggests a next step', () => {
    expect(fixFor('Discord', null)).toMatch(/Send a test/);
    expect(fixFor('Email', 'timeout')).toMatch(/Gmail connection/);
  });
});
