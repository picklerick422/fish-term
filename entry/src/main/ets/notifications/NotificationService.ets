// entry/src/main/ets/notifications/NotificationService.ets
// Manages system notifications and icon badge via notificationManager.
// Handles deduplication (30s per tab+type), foreground/background gating,
// and preference-driven suppression.

import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { TaskEvent, TaskEventType } from './TaskEvent';
import { NotificationPrefs, DEFAULT_NOTIFICATION_PREFS } from '../store/ConnectionStore';

const NOTIFICATION_BASE_ID: number = 1000;
const DEDUP_MS: number = 30000;

export class NotificationService {
  private context: common.UIAbilityContext | null = null;
  // Dedup map: "tabId_eventType" -> last notify timestamp
  private lastNotify: Map<string, number> = new Map();
  // Set of tab IDs with currently active notifications
  private activeTabIds: Set<number> = new Set();
  private prefs: NotificationPrefs = DEFAULT_NOTIFICATION_PREFS;

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  updatePrefs(prefs: NotificationPrefs): void {
    this.prefs = prefs;
  }

  // Handle a task event. Checks preferences and foreground state.
  // Returns true if a system notification was actually published.
  handle(event: TaskEvent, isForeground: boolean): boolean {
    // Master switch
    if (!this.prefs.enabled) {
      return false;
    }
    // Per-type switches
    if (event.type === TaskEventType.TASK_COMPLETED && !this.prefs.taskCompleted) {
      return false;
    }
    if (event.type === TaskEventType.TASK_AWAITING_INPUT && !this.prefs.taskAwaitingInput) {
      return false;
    }
    // Background-only mode: skip system notification when app is in foreground
    if (this.prefs.onlyWhenBackground && isForeground) {
      return false;
    }
    // Deduplication
    if (this.isDuplicate(event)) {
      return false;
    }
    this.markNotified(event);
    this.publish(event);
    return true;
  }

  // Dismiss notification for a specific tab (called when user switches to tab).
  dismiss(tabId: number): void {
    notificationManager.cancel(NOTIFICATION_BASE_ID + tabId);
    this.activeTabIds.delete(tabId);
    // Clean dedup records for this tab so re-triggering works after switching
    const keysToDelete: string[] = [];
    this.lastNotify.forEach((_value: number, key: string): void => {
      if (key.startsWith(tabId.toString() + '_')) {
        keysToDelete.push(key);
      }
    });
    keysToDelete.forEach((key: string): void => {
      this.lastNotify.delete(key);
    });
  }

  // Dismiss all notifications (called on app exit).
  dismissAll(): void {
    notificationManager.cancelAll();
    this.lastNotify.clear();
    this.activeTabIds.clear();
  }

  private isDuplicate(event: TaskEvent): boolean {
    const key: string = `${event.tabId}_${event.type}`;
    const last: number | undefined = this.lastNotify.get(key);
    if (last !== undefined && (Date.now() - last) < DEDUP_MS) {
      return true;
    }
    return false;
  }

  private markNotified(event: TaskEvent): void {
    const key: string = `${event.tabId}_${event.type}`;
    this.lastNotify.set(key, Date.now());
  }

  private publish(event: TaskEvent): void {
    const title: string = event.type === TaskEventType.TASK_COMPLETED
      ? `「${event.tabTitle}」执行完成`
      : `「${event.tabTitle}」需要输入`;

    const notificationRequest: notificationManager.NotificationRequest = {
      id: NOTIFICATION_BASE_ID + event.tabId,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: event.detail ?? '',
          additionalText: ''
        }
      }
    };

    notificationManager.publish(notificationRequest).then((): void => {
      console.info(`[NotificationService] Published: tab=${event.tabId} type=${event.type}`);
      this.activeTabIds.add(event.tabId);
    }).catch((err: Error): void => {
      console.error(`[NotificationService] Publish failed: ${err.message}`);
    });
  }
}
