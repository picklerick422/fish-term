/**
 * AI Chat 协议类型定义
 *
 * 定义 WebSocket JSON 协议中所有事件和操作的类型，
 * 与 fish-ai Python 后端的 protocol.py 保持一致。
 */

// ── AI 会话连接状态 ──
export enum AISessionState {
  Idle = 'idle',
  Connecting = 'connecting',
  Connected = 'connected',
  Reconnecting = 'reconnecting',
  Closed = 'closed',
  Error = 'error'
}

// ── AI 连接配置 ──
export interface AIConnectConfig {
  host: string;
  port: number;
  token: string;
  model?: string;
  baseUrl?: string;
  apiKey?: string;
}

export const DEFAULT_AI_CONFIG: AIConnectConfig = {
  host: '172.16.105.2',
  port: 8766,
  token: '',
  model: '',
  baseUrl: '',
  apiKey: ''
};

// ── fish-ai → 客户端事件类型 ──

export interface AITextDeltaEvent {
  type: 'text_delta';
  content: string;
}

export interface AIToolStartEvent {
  type: 'tool_start';
  id: string;
  name: string;
  input: Record<string, Object>;
}

export interface AIToolProgressEvent {
  type: 'tool_progress';
  id: string;
  delta: string;
}

export interface AIToolEndEvent {
  type: 'tool_end';
  id: string;
  output: string;
  is_error: boolean;
}

export interface AIDoneEvent {
  type: 'done';
  total_tokens: number;
  num_turns?: number;
  total_cost_usd?: number;
}

export interface AIErrorEvent {
  type: 'error';
  message: string;
}

export interface FileTreeNode {
  name: string;
  type: 'directory' | 'file';
  path?: string;
  children?: FileTreeNode[];
}

export interface AIFileTreeEvent {
  type: 'filetree';
  tree: FileTreeNode[];
}

export type AIEvent =
  | AITextDeltaEvent
  | AIToolStartEvent
  | AIToolProgressEvent
  | AIToolEndEvent
  | AIDoneEvent
  | AIErrorEvent
  | AIFileTreeEvent;

// ── 客户端 → fish-ai 操作类型 ──

export interface ChatAction {
  action: 'send';
  text: string;
}

export interface CancelAction {
  action: 'cancel';
}

export interface OpenFileAction {
  action: 'open_file';
  path: string;
}

export interface PermissionResponseAction {
  action: 'permission_response';
  approved: boolean;
}

export type AIAction =
  | ChatAction
  | CancelAction
  | OpenFileAction
  | PermissionResponseAction;

// ── WebSocket 消息（发送给 fish-ai） ──

export interface ChatRequest {
  type: 'chat';
  id: string;
  message: string;
}

export interface CancelRequest {
  type: 'cancel';
}

export type AIRequest = ChatRequest | CancelRequest;
