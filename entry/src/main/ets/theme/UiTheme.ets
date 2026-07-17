// Design tokens for fish-term UI chrome. Two switchable schemes:
//   refined    — A · 深邃专业(default, refined version of the original look)
//   futuristic — B · 未来感(violet/cyan gradient, restrained glow)
// Single source of truth for UI colors — do not scatter hex values elsewhere.
// Pure-black overlay masks ('#000000' / '#CC000000') are the documented exception.

export type UiScheme = 'refined' | 'futuristic';

export interface UiTheme {
  // Background layers
  bgBase: string;        // window background
  bgChrome: string;      // tab strip / outer chrome
  bgSurface: string;     // cards / sheets
  bgElevated: string;    // floating elements / active tab
  bgInput: string;       // text input fill
  // Borders
  border: string;
  borderStrong: string;
  divider: string;
  // Text
  textPrimary: string;
  textDim: string;
  textFaint: string;     // placeholder / disabled
  textOnAccent: string;  // text drawn on accent-filled buttons
  // Accent & status
  accent: string;
  accentAlt: string;     // gradient end color; equals accent in refined (no gradient)
  accentGradient: boolean; // true → primary buttons / active pills use accent→accentAlt gradient
  success: string;
  successBg: string;     // translucent capsule background behind status text
  successBorder: string;
  warn: string;
  danger: string;
  dangerBg: string;      // translucent danger background (destructive hover)
  hoverOverlay: string;
  pressOverlay: string;
  glowAccent: string;    // shadow color for active elements; '#00000000' (invisible) in refined
  shadowCard: string;
}

// Shared corner radii (same for both schemes)
export const RADIUS_CARD: number = 10;
export const RADIUS_CONTROL: number = 8;
export const RADIUS_SHEET: number = 14;
export const RADIUS_PILL: number = 99;

export const REFINED_DARK_THEME: UiTheme = {
  bgBase: '#0B0D10',
  bgChrome: '#0C0F14',
  bgSurface: '#11161D',
  bgElevated: '#161D27',
  bgInput: '#0E1318',
  border: '#1E2630',
  borderStrong: '#28323F',
  divider: '#1A212B',
  textPrimary: '#F4F7FB',
  textDim: '#8A94A6',
  textFaint: '#5C6674',
  textOnAccent: '#06231F',
  accent: '#3DD6C4',
  accentAlt: '#3DD6C4',
  accentGradient: false,
  success: '#3DD6C4',
  successBg: '#143DD6C4',
  successBorder: '#333DD6C4',
  warn: '#FFB454',
  danger: '#FF6B6B',
  dangerBg: '#17FF6B6B',
  hoverOverlay: '#14FFFFFF',
  pressOverlay: '#1FFFFFFF',
  glowAccent: '#00000000',
  shadowCard: '#59000000'
};

export const FUTURISTIC_THEME: UiTheme = {
  bgBase: '#07070C',
  bgChrome: '#0C0C14',
  bgSurface: '#12121E',
  bgElevated: '#171724',
  bgInput: '#0D0D17',
  border: '#26263A',
  borderStrong: '#2E2E48',
  divider: '#1E1E30',
  textPrimary: '#EDEFF7',
  textDim: '#8A8AA3',
  textFaint: '#6E6E8A',
  textOnAccent: '#0C0C14',
  accent: '#7C6CFF',
  accentAlt: '#3DD6C4',
  accentGradient: true,
  success: '#3DD6C4',
  successBg: '#1F3DD6C4',
  successBorder: '#403DD6C4',
  warn: '#FFB454',
  danger: '#FF6B6B',
  dangerBg: '#17FF6B6B',
  hoverOverlay: '#0FFFFFFF',
  pressOverlay: '#1AFFFFFF',
  glowAccent: '#597C6CFF',
  shadowCard: '#66000000'
};

const STORAGE_KEY_THEME: string = 'uiTheme';
const STORAGE_KEY_SCHEME: string = 'uiScheme';

// Read/write hub for the active scheme. Reactivity flows through AppStorage:
// components declare @StorageLink('uiTheme') / @StorageLink('uiScheme') and
// refresh automatically when setScheme() swaps the stored objects.
export class UiThemeStore {
  static scheme(): UiScheme {
    const s: string | undefined = AppStorage.get<string>(STORAGE_KEY_SCHEME);
    return s === 'futuristic' ? 'futuristic' : 'refined';
  }

  static theme(): UiTheme {
    const t: UiTheme | undefined = AppStorage.get<UiTheme>(STORAGE_KEY_THEME);
    return t ?? REFINED_DARK_THEME;
  }

  static setScheme(scheme: UiScheme): void {
    AppStorage.setOrCreate(STORAGE_KEY_SCHEME, scheme);
    AppStorage.setOrCreate(STORAGE_KEY_THEME, scheme === 'futuristic' ? FUTURISTIC_THEME : REFINED_DARK_THEME);
  }
}
