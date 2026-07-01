// Pure font-size helpers. Mirrored in tools/verify/_fontscale.mjs for node tests.
export const DEFAULT_FONT_SIZE: number = 16;
export const MIN_FONT_SIZE: number = 10;
export const MAX_FONT_SIZE: number = 28;
export const FONT_STEP: number = 2;

export const DEFAULT_LINE_SPACING: number = 1.05;
export const MIN_LINE_SPACING: number = 1.0;
export const MAX_LINE_SPACING: number = 1.5;
export const LINE_SPACING_STEP: number = 0.05;

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

export function clampLineSpacing(n: number): number {
  if (!Number.isFinite(n)) {
    return DEFAULT_LINE_SPACING;
  }
  // Round to nearest step to keep the UI value clean.
  const steps = Math.round(n / LINE_SPACING_STEP);
  const r = steps * LINE_SPACING_STEP;
  if (r < MIN_LINE_SPACING) {
    return MIN_LINE_SPACING;
  }
  if (r > MAX_LINE_SPACING) {
    return MAX_LINE_SPACING;
  }
  return parseFloat(r.toFixed(2));
}

export function stepLineSpacing(current: number, deltaSteps: number): number {
  return clampLineSpacing(current + deltaSteps * LINE_SPACING_STEP);
}

// Font family options for the settings picker.
export interface FontOption {
  family: string;   // CSS font-family name used in ArkUI / native
  label: string;    // human-readable label in the picker
  category: 'ui' | 'terminal';
}

export const DEFAULT_UI_FONT: string = 'Inter';
export const DEFAULT_TERM_FONT: string = 'Noto Sans Mono';

export const UI_FONT_OPTIONS: FontOption[] = [
  { family: 'Inter', label: 'Inter (无衬线)', category: 'ui' },
  { family: 'Source Serif 4', label: 'Source Serif 4 (衬线)', category: 'ui' },
  { family: 'HarmonyOS Sans', label: 'HarmonyOS Sans', category: 'ui' },
  { family: 'Noto Sans SC', label: 'Noto Sans SC', category: 'ui' },
  { family: 'Claude Sans', label: 'Claude Sans', category: 'ui' },
  { family: 'monospace', label: 'Monospace (等宽)', category: 'ui' },
];

export const TERM_FONT_OPTIONS: FontOption[] = [
  { family: 'Noto Sans Mono', label: 'Noto Sans Mono', category: 'terminal' },
  { family: 'JetBrains Mono', label: 'JetBrains Mono', category: 'terminal' },
  { family: 'Fira Code', label: 'Fira Code', category: 'terminal' },
  { family: 'Cascadia Code', label: 'Cascadia Code', category: 'terminal' },
  { family: 'Source Code Pro', label: 'Source Code Pro', category: 'terminal' },
  { family: 'Claude Sans', label: 'Claude Sans (比例字体)', category: 'terminal' },
];

// Scale-font tuning parameters, only applicable when the terminal font is Claude Sans.
export const DEFAULT_FONT_SCALE_BOOST: number = 1.20;
export const MIN_FONT_SCALE_BOOST: number = 1.00;
export const MAX_FONT_SCALE_BOOST: number = 2.00;
export const FONT_SCALE_BOOST_STEP: number = 0.05;

export const DEFAULT_CJK_VERTICAL_OFFSET: number = -2.0;
export const MIN_CJK_VERTICAL_OFFSET: number = -10.0;
export const MAX_CJK_VERTICAL_OFFSET: number = 10.0;
export const CJK_VERTICAL_OFFSET_STEP: number = 0.5;

export const DEFAULT_CHARACTER_SPACING: number = 1.5;
export const MIN_CHARACTER_SPACING: number = 0.0;
export const MAX_CHARACTER_SPACING: number = 5.0;
export const CHARACTER_SPACING_STEP: number = 0.5;

export function isScaledFont(family: string): boolean {
  return family === 'Claude Sans';
}

export function clampFontScaleBoost(n: number): number {
  if (!Number.isFinite(n)) {
    return DEFAULT_FONT_SCALE_BOOST;
  }
  const steps = Math.round(n / FONT_SCALE_BOOST_STEP);
  const r = steps * FONT_SCALE_BOOST_STEP;
  return Math.max(MIN_FONT_SCALE_BOOST, Math.min(MAX_FONT_SCALE_BOOST, parseFloat(r.toFixed(2))));
}

export function clampCjkVerticalOffset(n: number): number {
  if (!Number.isFinite(n)) {
    return DEFAULT_CJK_VERTICAL_OFFSET;
  }
  const steps = Math.round(n / CJK_VERTICAL_OFFSET_STEP);
  const r = steps * CJK_VERTICAL_OFFSET_STEP;
  return Math.max(MIN_CJK_VERTICAL_OFFSET, Math.min(MAX_CJK_VERTICAL_OFFSET, parseFloat(r.toFixed(1))));
}

export function clampCharacterSpacing(n: number): number {
  if (!Number.isFinite(n)) {
    return DEFAULT_CHARACTER_SPACING;
  }
  const steps = Math.round(n / CHARACTER_SPACING_STEP);
  const r = steps * CHARACTER_SPACING_STEP;
  return Math.max(MIN_CHARACTER_SPACING, Math.min(MAX_CHARACTER_SPACING, parseFloat(r.toFixed(1))));
}
