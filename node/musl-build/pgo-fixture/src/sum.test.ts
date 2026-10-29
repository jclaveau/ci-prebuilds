import { describe, expect, it } from 'vitest';
import { groupByParity, sumSquares } from './sum';

describe('sum', () => {
  it('sums squares', () => {
    expect(sumSquares([1, 2, 3])).toBe(14);
  });

  it('groups by parity', () => {
    expect(groupByParity([1, 2, 3, 4])).toEqual(new Map([['even', [2, 4]], ['odd', [1, 3]]]));
  });
});
