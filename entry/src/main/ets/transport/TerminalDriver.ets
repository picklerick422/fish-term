// Transport abstraction. All drivers (fish-term WebSocket, local PTY, SSH) implement this.
// Dataflow (spec §3.3): controller input -> driver.write; driver output -> controller.feedBytes.

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
  // Raw output bytes. Drivers batch small frames before invoking this, so each
  // callback may carry a large buffer — feed it straight to the terminal.
  onOutputBytes(cb: (data: ArrayBuffer) => void): void;
  onStatus(cb: (s: DriverStatus) => void): void;
  onCwdChange(cb: (cwd: string) => void): void;
}

// Connection parameters for the fish-agent WebSocket transport.
export interface FishConnectConfig {
  host: string;
  port: number;
  token: string;
  tls: boolean;
  cwd?: string;
  shell?: string;
  sessionId?: string;  // non-empty on reconnect to restore prior PTY session
}
