import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { DriverState, DriverStatus, TerminalDriver, FishConnectConfig } from './TerminalDriver';
import { buildFishUrl } from './FishUrl';
import { Backoff } from './Backoff';

const HEARTBEAT_MS: number = 15000;

// --- Output batching ---------------------------------------------------------
// The server replays its ring-buffer snapshot as thousands of tiny WebSocket
// frames (measured: ~14.6k frames, median 114 B, for a 2.2 MB snapshot).
// Running the full per-frame pipeline (decode, regex scans, N-API crossing,
// vt_write) for each of those frames on the UI thread is what made cache
// restore take seconds.  Instead, binary frames are accumulated here and
// flushed as one large ArrayBuffer: immediately once FLUSH_THRESHOLD_BYTES
// have piled up, otherwise on a zero-delay trailing timer so interactive
// echo latency stays within a few milliseconds.
const FLUSH_THRESHOLD_BYTES: number = 262144; // 256 KB

// --- Replay (cache restore) tracking -----------------------------------------
// A connection opened with a known session_id attaches to an existing server
// session, which then replays its output buffer.  There is no explicit
// "replay done" protocol message (the server's resize control frame precedes
// the snapshot), so completion is detected by a quiet period after the last
// binary frame, with a hard cap as a fallback.
const REPLAY_QUIET_MS: number = 500;
const REPLAY_GUARD_MS: number = 15000;

interface ServerCtrl {
  type: string;
  dir?: string;
  error?: string;
  id?: string;  // session id from server on first connect
  state?: boolean; // awaiting_input state
}

export class FishWebSocketDriver implements TerminalDriver {
  private readonly config: FishConnectConfig;
  private ws: webSocket.WebSocket | null = null;
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  private readonly backoff: Backoff = new Backoff(1000, 30000);

  private outputBytesCb: ((data: ArrayBuffer) => void) | null = null;
  private statusCb: ((s: DriverStatus) => void) | null = null;
  private cwdCb: ((dir: string) => void) | null = null;
  private sessionIdCb: ((id: string) => void) | null = null;
  private replayStateCb: ((replaying: boolean) => void) | null = null;
  private awaitingInputCb: ((awaiting: boolean) => void) | null = null;

  private cols: number = 80;
  private rows: number = 24;
  private connected: boolean = false;
  private manualStop: boolean = false;
  private reconnectTimer: number = -1;
  private heartbeatTimer: number = -1;
  private sessionId: string = '';

  // Pending binary output not yet handed to the session (see batching note).
  private pendingFrames: ArrayBuffer[] = [];
  private pendingBytes: number = 0;
  private flushTimer: number = -1;

  // Replay state: true between a reconnect's `open` and the end of the
  // server's snapshot burst.
  private replaying: boolean = false;
  private replayQuietTimer: number = -1;
  private replayGuardTimer: number = -1;

  constructor(config: FishConnectConfig) {
    this.config = config;
  }

  onOutputBytes(cb: (data: ArrayBuffer) => void): void {
    this.outputBytesCb = cb;
  }

  onStatus(cb: (s: DriverStatus) => void): void {
    this.statusCb = cb;
  }

  // Optional: server pushes cwd updates; used for tab titles in later phases.
  onCwd(cb: (dir: string) => void): void {
    this.cwdCb = cb;
  }

  // TerminalDriver interface compliance.
  onCwdChange(cb: (cwd: string) => void): void {
    this.cwdCb = cb;
  }

  // Server sends session id on first connect; page persists it for tab restore.
  onSessionId(cb: (id: string) => void): void {
    this.sessionIdCb = cb;
  }

  getSessionId(): string {
    return this.sessionId;
  }

  // Fires with `true` when a reconnect begins receiving the server's cached
  // output replay, and with `false` once the replay burst has ended.  Used to
  // drive the full-screen loading overlay and to mute replay-time analysis.
  onReplayState(cb: (replaying: boolean) => void): void {
    this.replayStateCb = cb;
  }

  // Backend-driven awaiting-input signal.  Fires when the fish-agent detects
  // the child process is idle and blocked on terminal input (3 s output
  // silence + process in S state).  Fires with `false` once output resumes.
  onAwaitingInput(cb: (awaiting: boolean) => void): void {
    this.awaitingInputCb = cb;
  }

  start(cols: number, rows: number): void {
    this.cols = Math.max(1, cols);
    this.rows = Math.max(1, rows);
    this.manualStop = false;
    this.backoff.reset();
    this.connect();
  }

  write(data: string): void {
    if (!this.connected || !this.ws || data.length === 0) {
      return;
    }
    const bytes: Uint8Array = this.encoder.encodeInto(data);
    const buffer: ArrayBuffer = bytes.buffer.slice(
      bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    this.ws.send(buffer).catch((err: BusinessError) => {
      console.error('fish-term send failed: ' + JSON.stringify(err));
    });
  }

  resize(cols: number, rows: number): void {
    this.cols = Math.max(1, cols);
    this.rows = Math.max(1, rows);
    if (this.connected && this.ws) {
      this.sendText(`{"type":"resize","cols":${this.cols},"rows":${this.rows}}`);
    }
  }

  onForeground(): void {
    if (this.manualStop || this.connected || this.reconnectTimer >= 0) {
      return;
    }
    // App returned to foreground while a reconnect was pending — trigger
    // an immediate reconnect attempt rather than waiting for the next backoff tick.
    this.backoff.reset();
    this.connect();
  }

  // Force an immediate (re)connect attempt, bypassing the backoff wait. Used by
  // the in-app "立即重连" button on the connection-status banner.
  reconnectNow(): void {
    this.manualStop = false;
    if (this.connected) {
      return;
    }
    this.clearReconnect();
    this.backoff.reset();
    this.connect();
  }

  stop(): void {
    this.manualStop = true;
    this.clearReconnect();
    this.stopHeartbeat();
    this.connected = false;
    if (this.ws) {
      const closing: webSocket.WebSocket = this.ws;
      this.ws = null;
      closing.close().catch((err: BusinessError) => {
        console.error('fish-term close failed: ' + JSON.stringify(err));
      });
    }
    this.endReplay();
    this.discardPendingFrames();
    this.emit(DriverState.Closed);
  }

  private connect(): void {
    this.clearReconnect();
    this.discardPendingFrames();
    const url: string = buildFishUrl(this.config, this.cols, this.rows);
    const ws: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = ws;
    this.emit(DriverState.Connecting);

    ws.on('open', () => {
      this.connected = true;
      this.backoff.reset();
      this.emit(DriverState.Connected);
      this.startHeartbeat();
      // Attaching to a known session makes the server replay its output
      // buffer; announce the replay so the page can show the loading overlay.
      if (this.expectsReplay()) {
        this.beginReplay();
      }
      // Send initial resize to trigger server-side screen redraw after reconnect.
      this.sendText(`{"type":"resize","cols":${this.cols},"rows":${this.rows}}`);
    });

    ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      this.onMessage(value);
    });

    ws.on('close', (_err: BusinessError, _info: webSocket.CloseResult) => {
      this.connected = false;
      this.stopHeartbeat();
      this.endReplay();
      this.discardPendingFrames();
      if (this.manualStop) {
        this.emit(DriverState.Closed);
        return;
      }
      this.emit(DriverState.Reconnecting);
      this.scheduleReconnect();
    });

    ws.on('error', (err: BusinessError) => {
      this.endReplay();
      this.emit(DriverState.Error, 'connection error (' + err.code + ')');
    });

    ws.connect(url, (err: BusinessError, _ok: boolean) => {
      if (err) {
        this.emit(DriverState.Error, 'connect failed (' + err.code + ')');
        if (!this.manualStop) {
          this.scheduleReconnect();
        }
      }
    });
  }

  private onMessage(value: string | ArrayBuffer): void {
    if (typeof value === 'string') {
      this.handleCtrl(value);
      return;
    }
    if (value.byteLength === 0) {
      return;
    }
    // Binary output frame — batch it (see batching note at the top).
    if (this.replaying) {
      this.armReplayQuietTimer();
    }
    this.pendingFrames.push(value);
    this.pendingBytes += value.byteLength;
    if (this.pendingBytes >= FLUSH_THRESHOLD_BYTES) {
      this.flushPendingFrames();
    } else if (this.flushTimer < 0) {
      this.flushTimer = setTimeout((): void => {
        this.flushTimer = -1;
        this.flushPendingFrames();
      }, 0) as number;
    }
  }

  // Merge accumulated frames into one buffer and hand it to the session.
  // Synchronous so a threshold flush keeps big bursts inside one task.
  private flushPendingFrames(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    if (this.pendingFrames.length === 0) {
      return;
    }
    let merged: ArrayBuffer;
    if (this.pendingFrames.length === 1) {
      merged = this.pendingFrames[0];
    } else {
      // NOTE: assign new ArrayBuffer(...) directly — Uint8Array.buffer is
      // ArrayBufferLike, which ArkTS rejects under arkts-no-structural-typing.
      merged = new ArrayBuffer(this.pendingBytes);
      const out: Uint8Array = new Uint8Array(merged);
      let offset: number = 0;
      for (let i: number = 0; i < this.pendingFrames.length; i++) {
        out.set(new Uint8Array(this.pendingFrames[i]), offset);
        offset += this.pendingFrames[i].byteLength;
      }
    }
    this.pendingFrames = [];
    this.pendingBytes = 0;
    if (this.outputBytesCb) {
      this.outputBytesCb(merged);
    }
  }

  private discardPendingFrames(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.pendingFrames = [];
    this.pendingBytes = 0;
  }

  // --- replay (cache restore) tracking ---------------------------------------

  private expectsReplay(): boolean {
    const configured: string = this.config.sessionId ?? '';
    return configured.length > 0 || this.sessionId.length > 0;
  }

  private beginReplay(): void {
    this.clearReplayTimers();
    this.replaying = true;
    if (this.replayStateCb) {
      this.replayStateCb(true);
    }
    // Arm the quiet timer up front too: a replay with an (almost) empty buffer
    // produces few or no binary frames, and must not wait for the guard.
    this.armReplayQuietTimer();
    // Fallback: never leave the loading overlay up if the replay stalls.
    this.replayGuardTimer = setTimeout((): void => {
      this.replayGuardTimer = -1;
      this.endReplay();
    }, REPLAY_GUARD_MS) as number;
  }

  private armReplayQuietTimer(): void {
    if (this.replayQuietTimer >= 0) {
      clearTimeout(this.replayQuietTimer);
    }
    this.replayQuietTimer = setTimeout((): void => {
      this.replayQuietTimer = -1;
      this.endReplay();
    }, REPLAY_QUIET_MS) as number;
  }

  private endReplay(): void {
    if (!this.replaying) {
      return;
    }
    this.clearReplayTimers();
    this.replaying = false;
    // Deliver any buffered tail before announcing completion so the screen is
    // fully restored when the overlay hides.
    this.flushPendingFrames();
    if (this.replayStateCb) {
      this.replayStateCb(false);
    }
  }

  private clearReplayTimers(): void {
    if (this.replayQuietTimer >= 0) {
      clearTimeout(this.replayQuietTimer);
      this.replayQuietTimer = -1;
    }
    if (this.replayGuardTimer >= 0) {
      clearTimeout(this.replayGuardTimer);
      this.replayGuardTimer = -1;
    }
  }

  private handleCtrl(text: string): void {
    let ctrl: ServerCtrl;
    try {
      ctrl = JSON.parse(text) as ServerCtrl;
    } catch (err) {
      console.error('fish-term bad ctrl frame: ' + text);
      return;
    }
    if (ctrl.type === 'error') {
      this.endReplay();  // e.g. stale session_id — no snapshot will follow
      // If the server says the session is gone, clear the cached session_id
      // so the next reconnect creates a fresh session instead of looping on a
      // dead session_id. The server push a new session id on fresh connect.
      if (ctrl.error && (ctrl.error.includes('session not found') || ctrl.error.includes('expired'))) {
        (this.config as Record<string, string | undefined>).sessionId = undefined;
        this.sessionId = '';
        // Reset backoff so the reconnect happens quickly with the fresh session.
        this.backoff.reset();
      }
      this.emit(DriverState.Error, ctrl.error ?? 'server error');
    } else if (ctrl.type === 'cwd') {
      if (this.cwdCb && ctrl.dir) {
        this.cwdCb(ctrl.dir);
      }
    } else if (ctrl.type === 'session' && ctrl.id) {
      this.sessionId = ctrl.id;
      if (this.sessionIdCb) {
        this.sessionIdCb(ctrl.id);
      }
    } else if (ctrl.type === 'awaiting_input') {
      if (this.awaitingInputCb) {
        this.awaitingInputCb(ctrl.state ?? false);
      }
    }
    // 'shells' / 'forked' ignored in v1.
  }

  private sendText(json: string): void {
    if (!this.ws) {
      return;
    }
    this.ws.send(json).catch((err: BusinessError) => {
      console.error('fish-term sendText failed: ' + JSON.stringify(err));
    });
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.connected) {
        this.sendText(`{"type":"ping","ts":${Date.now()}}`);
      }
    }, HEARTBEAT_MS) as number;
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private scheduleReconnect(): void {
    if (this.manualStop || this.reconnectTimer >= 0) {
      return;
    }
    const delay: number = this.backoff.next();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (!this.manualStop) {
        this.connect();
      }
    }, delay) as number;
  }

  private clearReconnect(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private emit(state: DriverState, message?: string): void {
    if (this.statusCb) {
      this.statusCb({ state, message });
    }
  }
}
