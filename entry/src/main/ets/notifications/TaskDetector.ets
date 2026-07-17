// entry/src/main/ets/notifications/TaskDetector.ets
// Detects task-completion and awaiting-input events from terminal output.
// Primary signal: Bell (BEL \x07). Fallback: regex pattern matching.

import { TaskEvent, TaskEventType } from './TaskEvent';

// Completion patterns — conservative to avoid false positives.
// Bell is the primary signal; these patterns catch tools that don't ring bell.
const COMPLETION_PATTERNS: RegExp[] = [
  // Structured exit code messages (e.g. "[Process exited with code 0]")
  /exit\s*code:\s*0/i,
  /Process\s+exited(?:\s+successfully)?/i,
];

// Patterns indicating the task is paused and needs user interaction.
const AWAITING_PATTERNS: RegExp[] = [
  /Press\s+(Enter|any\s*key|return)/i,
  /\(\s*[yYnN]\s*\/\s*[yYnN]\s*\)/,
  /\[\s*[yYnN]\s*\/\s*[yYnN]\s*\]/,
  /Waiting\s+for\s+(user\s+)?input/i,
];

const MAX_DETAIL_LENGTH: number = 80;

export class TaskDetector {
  // Whether to treat the BEL character (\x07) as a task-completion signal.
  // Defaults to false because many terminal operations (vim, backspace,
  // tab-completion failures, etc.) ring the bell, causing false positives.
  bellEnabled: boolean = false;

  // Analyze a chunk of terminal output.
  // Returns a TaskEvent if a task state change is detected, null otherwise.
  detect(data: string, tabId: number, tabTitle: string): TaskEvent | null {
    // 1. Bell detection — optional, controlled by preference
    if (this.bellEnabled && data.indexOf('\x07') >= 0) {
      return {
        type: TaskEventType.TASK_COMPLETED,
        tabId: tabId,
        tabTitle: tabTitle,
        detail: '终端响铃 (BEL)',
        timestamp: Date.now(),
      };
    }

    // 2. Completion pattern matching (fallback)
    for (let i: number = 0; i < COMPLETION_PATTERNS.length; i++) {
      const match: RegExpExecArray | null = COMPLETION_PATTERNS[i].exec(data);
      if (match !== null) {
        const snippet: string = match[0].length > MAX_DETAIL_LENGTH
          ? match[0].substring(0, MAX_DETAIL_LENGTH) + '…'
          : match[0];
        return {
          type: TaskEventType.TASK_COMPLETED,
          tabId: tabId,
          tabTitle: tabTitle,
          detail: snippet,
          timestamp: Date.now(),
        };
      }
    }

    // 3. Awaiting-input pattern matching
    for (let i: number = 0; i < AWAITING_PATTERNS.length; i++) {
      const match: RegExpExecArray | null = AWAITING_PATTERNS[i].exec(data);
      if (match !== null) {
        const snippet: string = match[0].length > MAX_DETAIL_LENGTH
          ? match[0].substring(0, MAX_DETAIL_LENGTH) + '…'
          : match[0];
        return {
          type: TaskEventType.TASK_AWAITING_INPUT,
          tabId: tabId,
          tabTitle: tabTitle,
          detail: snippet,
          timestamp: Date.now(),
        };
      }
    }

    return null;
  }
}
