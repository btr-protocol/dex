export function utilizationScore(volTvlRatio: number, exponent = 1.5): number {
  if (volTvlRatio < 0) return 0;
  return 1 - Math.exp(-exponent * volTvlRatio);
}
