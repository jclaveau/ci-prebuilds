import { groupByParity, sumSquares } from './sum';

const sampleValues = Array.from({ length: 100 }, (_, index) => index);
const appElement = document.querySelector<HTMLDivElement>('#app')!;
appElement.textContent = `${sumSquares(sampleValues)} / ${groupByParity(sampleValues).get('odd')!.length}`;
