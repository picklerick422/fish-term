// Minimal theme contract for TerminalSurface's own overlays (search bar,
// text fallback). Defaults reproduce the library's built-in dark look so the
// HAR stays usable without a host theme. Hosts pass their own tokens via
// the `surfaceTheme` prop — structural typing, no import of app code.

export interface SurfaceTheme {
  bgSurface: string;
  bgInput: string;
  border: string;
  textPrimary: string;
  textDim: string;
  accent: string;
  danger: string;
  dangerBg: string;
  hoverOverlay: string;
  overlayShadow: string;
  textFallback: string;
}

export const DEFAULT_SURFACE_THEME: SurfaceTheme = {
  bgSurface: '#11161D',
  bgInput: '#0E1318',
  border: '#1E2630',
  textPrimary: '#F4F7FB',
  textDim: '#8A94A6',
  accent: '#3DD6C4',
  danger: '#FF6B6B',
  dangerBg: '#17FF6B6B',
  hoverOverlay: '#1FFFFFFF',
  overlayShadow: '#4D000000',
  textFallback: '#D8DEE9'
};
