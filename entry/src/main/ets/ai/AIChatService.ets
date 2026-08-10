import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import {
  AIConnectConfig, AISessionState, AIEvent, AIRequest, ChatRequest, CancelRequest
} from './AITypes';
import { Backoff } from '../transport/Backoff';

/**
 * AI Chat WebSocket 连接管理
 *
 * 每个 Tab 一个实例，管理到 fish-ai 的 WebSocket 连接。
 * 模式对齐 FishWebSocketDriver：Backoff 重连、状态回调、send/cancel。
 */
const HEARTBEAT_MS: number = 30000;

export class AIChatService {
  private readonly config: AIConnectConfig;
  private ws: webSocket.WebSocket | null = null;
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  private readonly backoff: Backoff = new Backoff(1000, 30000);
  private state: AISessionState = AISessionState.Idle;
  private connected: boolean = false;
  private manualStop: boolean = false;
  private reconnectTimer: number = -1;
  private heartbeatTimer: number = -1;
  private onEventCb: ((event: AIEvent) => void) | null = null;
  private onStateChangeCb: ((state: AISessionState) => void) | null = null;
  private msgCounter: number = 0;

  constructor(config: AIConnectConfig) {
    this.config = config;
  }

  set onEvent(cb: (event: AIEvent) => void) {
    this.onEventCb = cb;
  }

  set onStateChange(cb: (state: AISessionState) => void) {
    this.onStateChangeCb = cb;
  }

  getState(): AISessionState {
    return this.state;
  }

  isConnected(): boolean {
    return this.connected;
  }

  connect(): void {
    this.manualStop = false;
    this.backoff.reset();
    this.doConnect();
  }

  disconnect(): void {
    this.manualStop = true;
    this.clearReconnect();
    this.stopHeartbeat();
    this.connected = false;
    if (this.ws) {
      const closing: webSocket.WebSocket = this.ws;
      this.ws = null;
      closing.close().catch((err: BusinessError) => {
        console.error('fish-ai close failed: ' + JSON.stringify(err));
      });
    }
    this.setState(AISessionState.Closed);
  }

  send(message: string): void {
    if (!this.connected || !this.ws) {
      return;
    }
    const id: string = 'msg_' + (++this.msgCounter);
    const req: ChatRequest = { type: 'chat', id, message };
    this.sendText(JSON.stringify(req));
  }

  cancel(): void {
    if (!this.connected || !this.ws) {
      return;
    }
    const req: CancelRequest = { type: 'cancel' };
    this.sendText(JSON.stringify(req));
  }

  private doConnect(): void {
    this.clearReconnect();
    const token: string = this.config.token.length > 0 ? this.config.token : 'none';
    const url: string = `ws://${this.config.host}:${this.config.port}/ws?token=${token}`;
    const ws: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = ws;
    this.setState(AISessionState.Connecting);

    ws.on('open', () => {
      this.connected = true;
      this.backoff.reset();
      this.setState(AISessionState.Connected);
      this.startHeartbeat();
      // Send configure if model/baseUrl/apiKey specified
      if (this.config.model || this.config.baseUrl || this.config.apiKey) {
        this.sendText(JSON.stringify({
          type: 'configure',
          model: this.config.model || undefined,
          base_url: this.config.baseUrl || undefined,
          api_key: this.config.apiKey || undefined
        }));
      }
    });

    ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value === 'string') {
        this.handleMessage(value);
      }
    });

    ws.on('close', (_err: BusinessError, _info: webSocket.CloseResult) => {
      this.connected = false;
      this.stopHeartbeat();
      if (this.manualStop) {
        this.setState(AISessionState.Closed);
        return;
      }
      this.setState(AISessionState.Reconnecting);
      this.scheduleReconnect();
    });

    ws.on('error', (err: BusinessError) => {
      console.error('fish-ai ws error: ' + JSON.stringify(err));
    });

    ws.connect(url, (err: BusinessError, _ok: boolean) => {
      if (err) {
        console.error('fish-ai connect failed: ' + JSON.stringify(err));
        if (!this.manualStop) {
          this.scheduleReconnect();
        }
      }
    });
  }

  private handleMessage(text: string): void {
    try {
      const event: AIEvent = JSON.parse(text) as AIEvent;
      if (this.onEventCb) {
        this.onEventCb(event);
      }
    } catch (e) {
      console.error('fish-ai bad message: ' + text);
    }
  }

  private sendText(json: string): void {
    if (!this.ws) {
      return;
    }
    this.ws.send(json).catch((err: BusinessError) => {
      console.error('fish-ai sendText failed: ' + JSON.stringify(err));
    });
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.connected) {
        this.sendText(JSON.stringify({ type: 'ping' }));
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
        this.doConnect();
      }
    }, delay) as number;
  }

  private clearReconnect(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private setState(state: AISessionState): void {
    this.state = state;
    if (this.onStateChangeCb) {
      this.onStateChangeCb(state);
    }
  }
}
