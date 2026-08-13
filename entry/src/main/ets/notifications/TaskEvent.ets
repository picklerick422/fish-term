// entry/src/main/ets/notifications/TaskEvent.ets
// Task event types emitted by claude-code hook events relayed through
// fish-agent (Stop -> completed, Notification/permission_prompt -> awaiting).

export enum TaskEventType {
  TASK_COMPLETED = 'completed',
  TASK_AWAITING_INPUT = 'awaiting',
}

export interface TaskEvent {
  type: TaskEventType;
  tabId: number;
  tabTitle: string;
  detail?: string;   // 匹配到的文本片段（用于通知 body）
  timestamp: number;
}
