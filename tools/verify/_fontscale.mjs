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

export const DEFAULT_LINE_SPACING = 1.05;
export const MIN_LINE_SPACING = 1.0;
export const MAX_LINE_SPACING = 1.5;
export const LINE_SPACING_STEP = 0.05;

export function clampLineSpacing(n) {
  if (!Number.isFinite(n)) return DEFAULT_LINE_SPACING;
  const steps = Math.round(n / LINE_SPACING_STEP);
  const r = steps * LINE_SPACING_STEP;
  if (r < MIN_LINE_SPACING) return MIN_LINE_SPACING;
  if (r > MAX_LINE_SPACING) return MAX_LINE_SPACING;
  return parseFloat(r.toFixed(2));
}

export function stepLineSpacing(current, deltaSteps) {
  return clampLineSpacing(current + deltaSteps * LINE_SPACING_STEP);
}
