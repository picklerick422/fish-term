import { util } from '@kit.ArkTS';
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

// Decode bounds for the auxiliary string analysis done per output batch.
// The terminal itself is fed raw bytes — strings are only needed for OSC
// title extraction and task-pattern detection, so we decode small slices
// instead of the whole batch (which can be hundreds of KB during replay).
const TITLE_SCAN_BYTES: number = 65536; // first 64 KB of a batch
const TASK_SCAN_BYTES: number = 4096;   // last 4 KB of a batch

export class TerminalSession {
  private readonly controller: TerminalController;
  private readonly driver: TerminalDriver;
  private statusCb: ((s: DriverStatus) => void) | null = null;
  private titleCb: ((title: string) => void) | null = null;
  private cwdCb: ((cwd: string) => void) | null = null;
  private sessionIdCb: ((id: string) => void) | null = null;
  private taskDataCb: ((data: string) => void) | null = null;
  private replayStateCb: ((replaying: boolean) => void) | null = null;

  private started: boolean = false;
  private stopped: boolean = false;
  private hasConnected: boolean = false;
  private startRetryTimer: number = -1;
  private lastCols: number = 0;
  private lastRows: number = 0;
  // True while the driver is receiving the server's cached-output replay.
  // Task detection is muted during replay — historical output must not fire
  // "task completed / awaiting input" notifications.
  private replaying: boolean = false;
  private readonly sliceDecoder: util.TextDecoder =
    util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
  private readonly decodeOpts: util.DecodeToStringOptions = { stream: false };

  constructor(controller: TerminalController, driver: TerminalDriver) {
    this.controller = controller;
    this.driver = driver;
    this.driver.onOutputBytes((data: ArrayBuffer): void => {
      if (this.stopped) {
        return;
      }
      // Feed raw bytes straight to the terminal — no string conversion on the
      // UI thread.  The VT parser is a streaming state machine, so partial
      // escape sequences / UTF-8 characters at batch boundaries resume safely.
      this.controller.feedBytes(data);
      // OSC title: decode only the batch prefix (titles appear early).
      const title: string | null =
        extractOscTitle(this.decodeSlice(data, 0, TITLE_SCAN_BYTES));
      if (title !== null) {
        console.info(`[TerminalSession] OSC title detected: "${title}"`);
        if (this.titleCb) {
          this.titleCb(title);
        } else {
          console.warn('[TerminalSession] titleCb is null, callback not registered');
        }
      }
      // Task detection: recent output only, and never during replay.
      if (this.taskDataCb && !this.replaying) {
        const tailStart: number = Math.max(0, data.byteLength - TASK_SCAN_BYTES);
        this.taskDataCb(this.decodeSlice(data, tailStart, data.byteLength - tailStart));
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
      (this.driver as FishWebSocketDriver).onReplayState((replaying: boolean): void => {
        this.replaying = replaying;
        if (this.replayStateCb) {
          this.replayStateCb(replaying);
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

  // Fires when the driver starts/finishes receiving the server's cached-output
  // replay after a reconnect. The page uses this to drive the loading overlay.
  onReplayState(cb: (replaying: boolean) => void): void {
    this.replayStateCb = cb;
  }

  // Decode a [start, start+len) window of a batch for auxiliary analysis.
  // One-shot (non-streaming) decode: partial characters at slice edges become
  // U+FFFD, which is harmless for title/pattern matching.
  private decodeSlice(data: ArrayBuffer, start: number, len: number): string {
    if (len <= 0 || start >= data.byteLength) {
      return '';
    }
    const clamped: number = Math.min(len, data.byteLength - start);
    return this.sliceDecoder.decodeToString(new Uint8Array(data, start, clamped), this.decodeOpts);
  }

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
