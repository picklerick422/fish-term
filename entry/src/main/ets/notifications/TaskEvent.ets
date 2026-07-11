// entry/src/main/ets/notifications/TaskEvent.ets
// Task event types emitted by TaskDetector from terminal output analysis.

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
