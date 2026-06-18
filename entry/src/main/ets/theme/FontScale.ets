// Pure font-size helpers. Mirrored in tools/verify/_fontscale.mjs for node tests.
export const DEFAULT_FONT_SIZE: number = 16;
export const MIN_FONT_SIZE: number = 10;
export const MAX_FONT_SIZE: number = 28;
export const FONT_STEP: number = 2;

export function clampFontSize(n: number): number {
  if (!Number.isFinite(n)) {
    return DEFAULT_FONT_SIZE;
  }
  const r: number = Math.round(n);
  if (r < MIN_FONT_SIZE) {
    return MIN_FONT_SIZE;
  }
  if (r > MAX_FONT_SIZE) {
    return MAX_FONT_SIZE;
  }
  return r;
}

export function stepFontSize(current: number, deltaSteps: number): number {
  return clampFontSize(current + deltaSteps * FONT_STEP);
}
