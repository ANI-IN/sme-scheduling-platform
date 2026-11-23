import { describe, expect, it } from 'vitest';
import {
  DEFAULT_CLASS_TIMES,
  classTimeText,
  dayLabel,
  nextClassTime,
  withClassType,
} from './classTimes';

describe('DEFAULT_CLASS_TIMES', () => {
  it('is the live class on Sunday 9:00 AM to 1:00 PM and the review on Thursday 6:00 PM to 8:00 PM', () => {
    expect(DEFAULT_CLASS_TIMES.map(classTimeText)).toEqual([
      'Live class: Sunday, 9:00 AM to 1:00 PM',
      'Assignment review: Thursday, 6:00 PM to 8:00 PM',
    ]);
  });
});

describe('dayLabel', () => {
  it('names the weekday of a class week that starts on Sunday', () => {
    expect([0, 1, 2, 3, 4, 5, 6].map(dayLabel)).toEqual([
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ]);
  });
  it('says the next week for days 7 to 13', () => {
    expect(dayLabel(7)).toBe('Sunday of the next week');
    expect(dayLabel(11)).toBe('Thursday of the next week');
    expect(dayLabel(13)).toBe('Saturday of the next week');
  });
});

describe('nextClassTime', () => {
  it('starts with the live class, then the review, then the live class again', () => {
    expect(nextClassTime([])).toEqual(DEFAULT_CLASS_TIMES[0]);
    expect(nextClassTime([{ class_type: 'Live class' }])).toEqual(DEFAULT_CLASS_TIMES[1]);
    expect(
      nextClassTime([{ class_type: 'Live class' }, { class_type: 'Assignment review' }]),
    ).toEqual(DEFAULT_CLASS_TIMES[0]);
  });
  it('gives a copy, so changing the form never changes the defaults', () => {
    const f = nextClassTime([]);
    f.start_time = '10:00';
    expect(DEFAULT_CLASS_TIMES[0]!.start_time).toBe('09:00');
  });
});

describe('withClassType', () => {
  it('moves to the default day and time of the new type while nothing was typed', () => {
    expect(withClassType({ ...DEFAULT_CLASS_TIMES[0]! }, 'Assignment review')).toEqual(
      DEFAULT_CLASS_TIMES[1],
    );
  });
  it('keeps what was typed', () => {
    const typed = { ...DEFAULT_CLASS_TIMES[0]!, start_time: '10:00' };
    expect(withClassType(typed, 'Assignment review')).toEqual({
      ...typed,
      class_type: 'Assignment review',
    });
  });
  it('keeps the day and time for a type without defaults', () => {
    expect(withClassType({ ...DEFAULT_CLASS_TIMES[1]! }, 'Office hours')).toEqual({
      ...DEFAULT_CLASS_TIMES[1],
      class_type: 'Office hours',
    });
  });
});
