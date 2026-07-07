// Centralized palette for the modern developer-tool look (accent = cyan).
// Single source of truth for colors — do not scatter hex values elsewhere.
export class Palette {
  static readonly base: string = '#0B0D10';     // page background
  static readonly surface: string = '#11161D';  // cards / status bar
  static readonly inputBg: string = '#0E1318';   // text input fill
  static readonly border: string = '#1E2630';    // hairline borders
  static readonly text: string = '#F4F7FB';      // primary text
  static readonly textDim: string = '#8A94A6';   // placeholder / subtitle
  static readonly accent: string = '#3DD6C4';    // cyan: focus, connect btn, connected dot
  static readonly warn: string = '#FFB454';      // reconnecting
  static readonly danger: string = '#FF6B6B';    // error / disconnect
}
