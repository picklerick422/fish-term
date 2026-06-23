import { TerminalController } from 'libghostty_ohos';
import { TerminalSession } from './TerminalSession';

// Non-reactive per-tab runtime. Owns the terminal controller (one native VT +
// its own XComponent surface) and the active driver session. These heavy objects
// live in a Map keyed by tab id on the page, separate from the reactive TabMeta
// array that drives the tab strip UI.
export class TerminalRuntime {
  readonly id: number;
  readonly surfaceId: string;
  readonly controller: TerminalController;
  session: TerminalSession | null = null;

  constructor(id: number) {
    this.id = id;
    this.surfaceId = 'fishTermSurface_' + id;
    this.controller = new TerminalController();
  }
}
