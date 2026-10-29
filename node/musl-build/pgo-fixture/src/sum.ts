export function sumSquares(values: readonly number[]): number {
  return values.reduce((total, value) => total + value * value, 0);
}

export function groupByParity(values: readonly number[]): Map<'even' | 'odd', number[]> {
  const parityGroups = new Map<'even' | 'odd', number[]>([['even', []], ['odd', []]]);
  for (const value of values) parityGroups.get(value % 2 === 0 ? 'even' : 'odd')!.push(value);
  return parityGroups;
}
