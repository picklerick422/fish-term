// Kept equivalent to entry/src/main/ets/theme/FontScale.ets
export const DEFAULT_FONT_SIZE = 16;
export const MIN_FONT_SIZE = 10;
export const MAX_FONT_SIZE = 28;
export const FONT_STEP = 2;

export function clampFontSize(n) {
  if (!Number.isFinite(n)) return DEFAULT_FONT_SIZE;
  const r = Math.round(n);
  if (r < MIN_FONT_SIZE) return MIN_FONT_SIZE;
  if (r > MAX_FONT_SIZE) return MAX_FONT_SIZE;
  return r;
}

export function stepFontSize(current, deltaSteps) {
  return clampFontSize(current + deltaSteps * FONT_STEP);
}
