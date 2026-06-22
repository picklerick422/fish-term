import { TerminalController, TerminalSize } from 'libghostty_ohos';
import { DriverState, DriverStatus, TerminalDriver } from '../transport/TerminalDriver';
import { FishWebSocketDriver } from '../transport/FishWebSocketDriver';

// Wires one driver to an externally-owned, persistent TerminalController
// (spec §3.3 dataflow). The controller + its XComponent surface are owned by the
// page and live for the whole page lifetime — this class never binds/unbinds the
// renderer. It only manages the driver and the controller's input/size listeners,
// so connect/disconnect never unmount the surface (which is what crashed before).
export class TerminalSession {
  private readonly controller: TerminalController;
  private readonly driver: TerminalDriver;
  private statusCb: ((s: DriverStatus) => void) | null = null;

  private started: boolean = false;
  private stopped: boolean = false;
  private hasConnected: boolean = false;
  private startRetryTimer: number = -1;
  private lastCols: number = 0;
  private lastRows: number = 0;

  constructor(controller: TerminalController, driver: TerminalDriver) {
    this.controller = controller;
    this.driver = driver;
    this.driver.onOutput((data: string): void => {
      if (!this.stopped) {
        this.controller.feed(data);
      }
    });
    this.driver.onStatus((s: DriverStatus): void => {
      if (s.state === DriverState.Connected) {
        // On a reconnect the server starts a fresh session; reset the emulator
        // first so modes the previous session enabled (mouse tracking, alt
        // screen, …) don't leak — otherwise the wheel gets reported as SGR
        // mouse sequences (e.g. "65;1;1M") to the new shell. This runs before
        // the server's replay output is fed, so the new state takes over.
        if (this.hasConnected && !this.stopped) {
          this.controller.resetTerminal();
        }
        this.hasConnected = true;
      }
      if (this.statusCb) {
        this.statusCb(s);
      }
    });
  }

  onStatus(cb: (s: DriverStatus) => void): void {
    this.statusCb = cb;
  }

  onForeground(): void {
    if (this.driver instanceof FishWebSocketDriver) {
      (this.driver as FishWebSocketDriver).onForeground();
    }
  }

  // Begin the driver. The surface is already bound (page mounts it once), so we
  // wire input/resize and start as soon as a valid size is available.
  start(): void {
    this.stopped = false;
    this.controller.setInputListener((data: string): void => {
      if (!this.stopped) {
        this.driver.write(data);
      }
    });
    this.controller.setSizeListener((size: TerminalSize): void => {
      if (!this.started || this.stopped) {
        return;
      }
      const cols: number = Math.max(1, size.cols || 0);
      const rows: number = Math.max(1, size.rows || 0);
      if (cols === this.lastCols && rows === this.lastRows) {
        return;
      }
      this.lastCols = cols;
      this.lastRows = rows;
      this.driver.resize(cols, rows);
    });
    this.startWhenSized();
  }

  // Stop the driver and detach our listeners from the shared controller. Leaves
  // the controller bound to its surface — the page keeps the renderer alive.
  stop(): void {
    this.stopped = true;
    if (this.startRetryTimer >= 0) {
      clearTimeout(this.startRetryTimer);
      this.startRetryTimer = -1;
    }
    this.controller.setInputListener(null);
    this.controller.setSizeListener(null);
    this.started = false;
    this.driver.stop();
  }

  private startWhenSized(): void {
    if (this.started || this.stopped) {
      return;
    }
    const size: TerminalSize = this.controller.getTerminalSize();
    const cols: number = Math.max(0, size.cols || 0);
    const rows: number = Math.max(0, size.rows || 0);
    if (cols <= 0 || rows <= 0) {
      if (this.startRetryTimer < 0) {
        this.startRetryTimer = setTimeout((): void => {
          this.startRetryTimer = -1;
          this.startWhenSized();
        }, 50) as number;
      }
      return;
    }
    this.started = true;
    this.lastCols = cols;
    this.lastRows = rows;
    this.driver.start(cols, rows);
  }
}
