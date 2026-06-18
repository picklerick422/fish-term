import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { DriverState, DriverStatus, TerminalDriver, WandConnectConfig } from './TerminalDriver';
import { Utf8Framer } from './Utf8Framer';
import { buildWandUrl } from './WandUrl';
import { Backoff } from './Backoff';

const HEARTBEAT_MS: number = 15000;
const MAX_RECONNECT_ATTEMPTS: number = 6;

interface ServerCtrl {
  type: string;
  dir?: string;
  error?: string;
}

export class WandWebSocketDriver implements TerminalDriver {
  private readonly config: WandConnectConfig;
  private ws: webSocket.WebSocket | null = null;
  private readonly framer: Utf8Framer = new Utf8Framer();
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  private readonly backoff: Backoff = new Backoff(1000, 30000);

  private outputCb: ((data: string) => void) | null = null;
  private statusCb: ((s: DriverStatus) => void) | null = null;
  private cwdCb: ((dir: string) => void) | null = null;

  private cols: number = 80;
  private rows: number = 24;
  private connected: boolean = false;
  private manualStop: boolean = false;
  private reconnectTimer: number = -1;
  private heartbeatTimer: number = -1;
  private reconnectAttempts: number = 0;

  constructor(config: WandConnectConfig) {
    this.config = config;
  }

  onOutput(cb: (data: string) => void): void {
    this.outputCb = cb;
  }

  onStatus(cb: (s: DriverStatus) => void): void {
    this.statusCb = cb;
  }

  // Optional: server pushes cwd updates; used for tab titles in later phases.
  onCwd(cb: (dir: string) => void): void {
    this.cwdCb = cb;
  }

  start(cols: number, rows: number): void {
    this.cols = Math.max(1, cols);
    this.rows = Math.max(1, rows);
    this.manualStop = false;
    this.reconnectAttempts = 0;
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
      console.error('wand send failed: ' + JSON.stringify(err));
    });
  }

  resize(cols: number, rows: number): void {
    this.cols = Math.max(1, cols);
    this.rows = Math.max(1, rows);
    if (this.connected && this.ws) {
      this.sendText(`{"type":"resize","cols":${this.cols},"rows":${this.rows}}`);
    }
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
        console.error('wand close failed: ' + JSON.stringify(err));
      });
    }
    this.framer.reset();
    this.emit(DriverState.Closed);
  }

  private connect(): void {
    this.clearReconnect();
    this.framer.reset();
    const url: string = buildWandUrl(this.config, this.cols, this.rows);
    const ws: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = ws;
    this.emit(DriverState.Connecting);

    ws.on('open', () => {
      this.connected = true;
      this.reconnectAttempts = 0;
      this.backoff.reset();
      this.emit(DriverState.Connected);
      this.startHeartbeat();
    });

    ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      this.onMessage(value);
    });

    ws.on('close', (_err: BusinessError, _info: webSocket.CloseResult) => {
      this.connected = false;
      this.stopHeartbeat();
      if (this.manualStop) {
        this.emit(DriverState.Closed);
        return;
      }
      this.emit(DriverState.Reconnecting);
      this.scheduleReconnect();
    });

    ws.on('error', (err: BusinessError) => {
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
    const text: string = this.framer.push(new Uint8Array(value));
    if (text.length > 0 && this.outputCb) {
      this.outputCb(text);
    }
  }

  private handleCtrl(text: string): void {
    let ctrl: ServerCtrl;
    try {
      ctrl = JSON.parse(text) as ServerCtrl;
    } catch (err) {
      console.error('wand bad ctrl frame: ' + text);
      return;
    }
    if (ctrl.type === 'error') {
      this.emit(DriverState.Error, ctrl.error ?? 'server error');
    } else if (ctrl.type === 'cwd') {
      if (this.cwdCb && ctrl.dir) {
        this.cwdCb(ctrl.dir);
      }
    }
    // 'shells' / 'forked' ignored in v1.
  }

  private sendText(json: string): void {
    if (!this.ws) {
      return;
    }
    this.ws.send(json).catch((err: BusinessError) => {
      console.error('wand sendText failed: ' + JSON.stringify(err));
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
    if (this.reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      // Give up so a bad token / unreachable host doesn't loop forever.
      // The user can fix the details and reconnect from the form.
      this.manualStop = true;
      this.emit(DriverState.Error, '重连失败，请检查地址和 token');
      return;
    }
    this.reconnectAttempts++;
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
