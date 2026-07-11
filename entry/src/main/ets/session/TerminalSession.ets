import { TerminalController, TerminalSize } from 'libghostty_ohos';
import { DriverState, DriverStatus, TerminalDriver } from '../transport/TerminalDriver';
import { FishWebSocketDriver } from '../transport/FishWebSocketDriver';

// Wires one driver to an externally-owned, persistent TerminalController
// (spec §3.3 dataflow). The controller + its XComponent surface are owned by the
// page and live for the whole page lifetime — this class never binds/unbinds the
// renderer. It only manages the driver and the controller's input/size listeners,
// so connect/disconnect never unmount the surface (which is what crashed before).
// Extract the last OSC 0/2 window title from a chunk of terminal output.
// Matches: ESC ] (0|1|2) ; <text> BEL
//
// Only scans the first 64 KB of data — OSC window titles always appear near
// the start of a session (shell prompt, etc.).  Scanning megabytes of replay
// data for title sequences blocks the main thread (ANR) because String.indexOf
// on 5 MB strings is CPU-bound.
function extractOscTitle(data: string): string | null {
  const SCAN_LIMIT: number = 65536; // 64 KB
  const scanEnd: number = Math.min(data.length, SCAN_LIMIT);
  let last: string | null = null;
  let i = 0;
  while (i < scanEnd) {
    const esc = data.indexOf('\x1b]', i);
    if (esc < 0 || esc >= scanEnd) break;
    const semi = data.indexOf(';', esc + 2);
    if (semi < 0 || semi >= scanEnd) break;
    const ps = data.substring(esc + 2, semi);
    if (ps === '0' || ps === '1' || ps === '2') {
      const bel = data.indexOf('\x07', semi + 1);
      const st = data.indexOf('\x1b\\', semi + 1);
      let end = -1;
      if (bel >= 0 && (st < 0 || bel < st)) end = bel;
      else if (st >= 0) end = st;
      if (end >= 0 && end < scanEnd) {
        last = data.substring(semi + 1, end);
        i = end + 1;
        continue;
      }
    }
    i = esc + 2;
  }
  return last;
}

export class TerminalSession {
  private readonly controller: TerminalController;
  private readonly driver: TerminalDriver;
  private statusCb: ((s: DriverStatus) => void) | null = null;
  private titleCb: ((title: string) => void) | null = null;
  private cwdCb: ((cwd: string) => void) | null = null;
  private sessionIdCb: ((id: string) => void) | null = null;
  private taskDataCb: ((data: string) => void) | null = null;

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
        const title = extractOscTitle(data);
        if (title !== null) {
          console.info(`[TerminalSession] OSC title detected: "${title}"`);
          if (this.titleCb) {
            this.titleCb(title);
          } else {
            console.warn('[TerminalSession] titleCb is null, callback not registered');
          }
        }
        // Feed in chunks when the data is large (e.g. server ring-buffer
        // replay on reconnect).  Processing megabytes synchronously on the
        // main thread blocks rendering and triggers the system ANR watchdog.
        this.feedChunked(data);
        // Forward raw output to task detector for notification analysis
        if (this.taskDataCb) {
          this.taskDataCb(data);
        }
      }
    });
    this.driver.onStatus((s: DriverStatus): void => {
      if (s.state === DriverState.Connected) {
        // On reconnect the server replays its ring-buffer snapshot.
        // Do NOT reset the emulator — that would clear the scrollback
        // and create a visible gap between pre-disconnect history and
        // the replay. The snapshot contains any mode-setting escape
        // sequences from the server, so stale modes (mouse tracking,
        // alt screen) are naturally overwritten as the replay is fed.
        this.hasConnected = true;
      }
      if (this.statusCb) {
        this.statusCb(s);
      }
    });
    this.driver.onCwdChange((cwd: string): void => {
      if (this.cwdCb) {
        this.cwdCb(cwd);
      }
    });
    // Forward session-id from the driver to the page so it can be persisted.
    if (this.driver instanceof FishWebSocketDriver) {
      (this.driver as FishWebSocketDriver).onSessionId((id: string): void => {
        if (this.sessionIdCb) {
          this.sessionIdCb(id);
        }
      });
    }
  }

  onStatus(cb: (s: DriverStatus) => void): void {
    this.statusCb = cb;
  }

  onTitleChange(cb: (title: string) => void): void {
    this.titleCb = cb;
  }

  onCwdChange(cb: (cwd: string) => void): void {
    this.cwdCb = cb;
  }

  onSessionId(cb: (id: string) => void): void {
    this.sessionIdCb = cb;
  }

  // Register a callback that receives the raw terminal output chunks.
  // TaskDetector hooks into this to analyze output for task state changes.
  onTaskData(cb: (data: string) => void): void {
    this.taskDataCb = cb;
  }

  // Max bytes to feed to the terminal emulator in one synchronous call.
  // Beyond this threshold data is split into chunks with setTimeout yields
  // between them so the main thread stays responsive (avoids THREAD_BLOCK_6S).
  private static readonly FEED_CHUNK_BYTES: number = 262144; // 256 KB

  onForeground(): void {
    if (this.driver instanceof FishWebSocketDriver) {
      (this.driver as FishWebSocketDriver).onForeground();
    }
  }

  // Force an immediate reconnect (skips the backoff wait). No-op once stopped.
  reconnectNow(): void {
    if (this.stopped) {
      return;
    }
    if (this.driver instanceof FishWebSocketDriver) {
      (this.driver as FishWebSocketDriver).reconnectNow();
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

  // Feed terminal output in chunks when it exceeds FEED_CHUNK_BYTES.
  // The terminal parser is a state machine — partial escape sequences at
  // chunk boundaries are safely resumed by the next chunk.  Yielding via
  // setTimeout(0) keeps the main thread responsive during bulk data
  // (e.g. server ring-buffer replay on reconnect).
  private feedChunked(data: string): void {
    if (data.length <= TerminalSession.FEED_CHUNK_BYTES) {
      this.controller.feed(data);
      return;
    }
    let offset: number = 0;
    const feedNext = (): void => {
      if (this.stopped || offset >= data.length) {
        return;
      }
      const end: number = Math.min(offset + TerminalSession.FEED_CHUNK_BYTES, data.length);
      this.controller.feed(data.substring(offset, end));
      offset = end;
      if (offset < data.length) {
        setTimeout(feedNext, 0);
      }
    };
    feedNext();
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
