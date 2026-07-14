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

// Option entry used by the test-notification UI selectors.
export interface OptionEntry {
  label: string;
  value: number;
}

// Test notification parameter bundle — exposed so the settings panel can
// configure every dimension for debugging.
export interface TestNotifyOptions {
  slotType: number;       // notificationManager.SlotType
  contentType: number;    // notificationManager.ContentType
  title: string;
  text: string;
}

// Slot-type options presented in the test UI.
export const SLOT_TYPE_OPTIONS: OptionEntry[] = [
  { label: '社交通信', value: 1 } as OptionEntry,   // SOCIAL_COMMUNICATION
  { label: '服务提醒', value: 2 } as OptionEntry,   // SERVICE_INFORMATION
  { label: '内容资讯', value: 3 } as OptionEntry,   // CONTENT_INFORMATION
  { label: '其他类型', value: 0xFFFF } as OptionEntry, // OTHER_TYPES
];

// Content-type options presented in the test UI.
export const CONTENT_TYPE_OPTIONS: OptionEntry[] = [
  { label: '基础文本', value: 0 } as OptionEntry,  // NOTIFICATION_CONTENT_BASIC_TEXT
  { label: '长文本', value: 1 } as OptionEntry,    // NOTIFICATION_CONTENT_LONG_TEXT
  { label: '多行文本', value: 2 } as OptionEntry,  // NOTIFICATION_CONTENT_MULTILINE
];

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

  // Publish a test notification with full control over slot, content type,
  // title and text — bypasses prefs and dedup. Returns the notification id.
  publishTest(opts: TestNotifyOptions): number {
    const slotType: number = opts.slotType;
    this.ensureSlot(slotType);

    const id: number = NOTIFICATION_BASE_ID;
    let content: notificationManager.NotificationContent;

    if (opts.contentType === 1) {
      // Long text
      content = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
        longText: {
          title: opts.title,
          text: opts.text,
          longText: opts.text,
          additionalText: '',
          briefText: opts.title,
          expandedTitle: opts.title
        }
      };
    } else if (opts.contentType === 2) {
      // Multi-line
      const lines: string[] = opts.text.split('\n');
      content = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_MULTILINE,
        multiLine: {
          title: opts.title,
          text: opts.text,
          additionalText: '',
          briefText: opts.title,
          longTitle: opts.title,
          lines: lines
        }
      };
    } else {
      // Basic text (default)
      content = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: opts.title,
          text: opts.text,
          additionalText: ''
        }
      };
    }

    const notificationRequest: notificationManager.NotificationRequest = {
      id: id,
      content: content,
      notificationSlotType: slotType as notificationManager.SlotType
    };

    notificationManager.publish(notificationRequest).then((): void => {
      console.info(`[NotificationService] Test published: slot=${slotType} content=${opts.contentType}`);
    }).catch((err: Error): void => {
      console.error(`[NotificationService] Test publish failed: ${err.message}`);
    });
    return id;
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

  private createdSlots: Set<number> = new Set();

  // Ensure a notification slot of the given type exists.
  // HarmonyOS requires a slot (channel) — without it publish fails with 1600005.
  private ensureSlot(slotType: number): void {
    if (this.createdSlots.has(slotType)) {
      return;
    }
    this.createdSlots.add(slotType);

    // ArkTS strict mode requires the enum value, not a bare number.
    const st: notificationManager.SlotType = slotType as notificationManager.SlotType;
    notificationManager.addSlot(st).then((): void => {
      console.info(`[NotificationService] Slot created (type=${slotType})`);
    }).catch((err: Error): void => {
      console.error(`[NotificationService] addSlot(type=${slotType}) failed: ${err.message}`);
    });
  }

  private publish(event: TaskEvent): void {
    this.ensureSlot(2); // SERVICE_INFORMATION for task notifications

    const title: string = event.type === TaskEventType.TASK_COMPLETED
      ? `「${event.tabTitle}」执行完成`
      : `「${event.tabTitle}」需要输入`;

    const notificationRequest: notificationManager.NotificationRequest = {
      id: NOTIFICATION_BASE_ID + event.tabId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: event.detail ?? '',
          additionalText: ''
        }
      }
    };

    // Log notification enable status (one-time) to aid debugging.
    notificationManager.isNotificationEnabled().then((enabled: boolean): void => {
      console.info(`[NotificationService] isNotificationEnabled = ${enabled}`);
    }).catch((_err: Error): void => {
      // Best-effort diagnostic, ignore errors
    });

    notificationManager.publish(notificationRequest).then((): void => {
      console.info(`[NotificationService] Published: tab=${event.tabId} type=${event.type}`);
      this.activeTabIds.add(event.tabId);
    }).catch((err: Error): void => {
      console.error(`[NotificationService] Publish failed: ${err.message} (code may be in err)`);
    });
  }
}
