// Transport abstraction. All drivers (wand WebSocket, local PTY, SSH) implement this.
// Dataflow (spec §3.3): controller input -> driver.write; driver output -> controller.feed.

export enum DriverState {
  Idle = 'idle',
  Connecting = 'connecting',
  Connected = 'connected',
  Reconnecting = 'reconnecting',
  Closed = 'closed',
  Error = 'error'
}

export interface DriverStatus {
  state: DriverState;
  message?: string;
}

export interface TerminalDriver {
  start(cols: number, rows: number): void;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  stop(): void;
  onOutput(cb: (data: string) => void): void;
  onStatus(cb: (s: DriverStatus) => void): void;
}

// Connection parameters for the wand-agent WebSocket transport (spec §4.3).
export interface WandConnectConfig {
  host: string;
  port: number;
  token: string;
  tls: boolean;
  cwd?: string;
  shell?: string;
}
