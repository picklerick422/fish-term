// CrashHandler.ets — 崩溃捕获协调层

import { errorManager } from '@kit.AbilityKit';
import { FaultLogger } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { CrashType, CrashLogEntry, CrashDeviceInfo } from './CrashTypes';
import { CrashStore } from './CrashStore';

// 模块级别的待展示崩溃入口，由 EntryAbility 设置，由 Index.ets 读取
let pendingEntry: CrashLogEntry | null = null;

// 匹配系统 FaultLogInfo 结构的本地类型
interface SysFaultEntry {
  pid: number;
  uid: number;
  type: number;
  timestamp: number;
  reason: string;
  module: string;
  summary: string;
  fullLog: string;
}

export class CrashHandler {
  private readonly store: CrashStore;
  private observerId: number = -1;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = new CrashStore(context);
  }

  // 注册全局 ArkTS 异常监听（在 EntryAbility.onCreate 中尽早调用）
  registerGlobalErrorHandler(): void {
    try {
      // 捕获 JS crash — 回调内进程不退出，建议处理后同步退出
      this.observerId = errorManager.on('error', {
        onUnhandledException: (errMsg: string) => {
          this.capture(CrashType.JS_CRASH, errMsg, errMsg);
          // 短暂延迟让写文件完成
          setTimeout(() => {
            // 不主动退出，让应用自然终止
          }, 500);
        }
      });
      console.info('CrashHandler: global error observer registered');
    } catch (e) {
      console.error('CrashHandler: failed to register error observer: ' + JSON.stringify(e));
    }
  }

  // 在 EntryAbility.onForeground 中调用，检查是否有待展示的崩溃
  checkPendingCrash(): CrashLogEntry | null {
    // 1. 先查 faultLogger（系统记录的崩溃）
    this.queryFaultLogger();
    // 2. 再查标记文件（我们自己写入的）
    const flagId = this.store.getFlag();
    if (flagId) {
      const entries = this.store.listEntries();
      for (const entry of entries) {
        if (entry.id === flagId && !entry.viewed) {
          pendingEntry = entry;
          return entry;
        }
      }
    }
    // 3. 如果没有标记但存在未查看的条目，取最新一条
    const entries = this.store.listEntries();
    for (const entry of entries) {
      if (!entry.viewed) {
        pendingEntry = entry;
        return entry;
      }
    }
    // 4. 检查 native 信号处理器写入的 .log 文件
    const nativeEntries = this.store.listNativeEntries();
    for (const entry of nativeEntries) {
      if (!entry.viewed) {
        pendingEntry = entry;
        return entry;
      }
    }
    return null;
  }

  // 获取待展示条目（由 Index.ets 的 aboutToAppear 调用）
  static consumePendingEntry(): CrashLogEntry | null {
    const entry = pendingEntry;
    pendingEntry = null;
    return entry;
  }

  // 由 Index.ets 在弹窗关闭时调用，标记已查看
  static hasPendingEntry(): boolean {
    return pendingEntry !== null;
  }

  // 正常退出时清理标记文件
  onDestroy(): void {
    // 取消注册异常观测器
    if (this.observerId >= 0) {
      try {
        errorManager.off('error', this.observerId);
        this.observerId = -1;
      } catch (_) {
        // ignore
      }
    }
    this.store.clearFlag();
  }

  // 查询 faultLogger 系统记录的崩溃并存入 CrashStore
  private queryFaultLogger(): void {
    try {
      // FaultType: CPP_CRASH=2, JS_CRASH=3, APP_FREEZE=4
      FaultLogger.query(2 /* CPP_CRASH */, (err: Error, infos: Array<SysFaultEntry>) => {
        if (!err && infos) {
          for (const info of infos) {
            this.saveFaultLog(CrashType.CPP_CRASH, info);
          }
        }
      });
      FaultLogger.query(3 /* JS_CRASH */, (err: Error, infos: Array<SysFaultEntry>) => {
        if (!err && infos) {
          for (const info of infos) {
            this.saveFaultLog(CrashType.JS_CRASH, info);
          }
        }
      });
      FaultLogger.query(4 /* APP_FREEZE */, (err: Error, infos: Array<SysFaultEntry>) => {
        if (!err && infos) {
          for (const info of infos) {
            this.saveFaultLog(CrashType.APP_FREEZE, info);
          }
        }
      });
    } catch (e) {
      console.error('CrashHandler: faultLogger query failed: ' + JSON.stringify(e));
    }
  }

  // 将 faultLogger 返回的记录转存为 CrashLogEntry
  private saveFaultLog(type: CrashType, info: SysFaultEntry): void {
    const timestamp = info.timestamp;
    const reason = info.reason || '';
    const summary = info.summary || '';
    const fullLog = info.fullLog || '';
    const id = 'fl_' + timestamp + '_' + type;
    const dateStr = this.formatTimestamp(timestamp);

    const entry: CrashLogEntry = {
      id: id,
      timestamp: timestamp,
      crashType: type,
      summary: reason || summary || type,
      stackTrace: fullLog || summary || '',
      systemLog: fullLog || '',
      deviceInfo: this.collectDeviceInfo(),
      logFileName: 'crash_' + dateStr + '_' + type + '.json',
      viewed: false
    };
    this.store.save(entry);
    this.store.setFlag(id);
  }

  // 实时捕获的崩溃
  capture(type: CrashType, summary: string, stackTrace: string): void {
    const timestamp = Date.now();
    const id = 'rt_' + timestamp + '_' + type;
    const dateStr = this.formatTimestamp(timestamp);

    const entry: CrashLogEntry = {
      id: id,
      timestamp: timestamp,
      crashType: type,
      summary: this.truncate(summary, 200),
      stackTrace: stackTrace,
      systemLog: '',
      deviceInfo: this.collectDeviceInfo(),
      logFileName: 'crash_' + dateStr + '_' + type + '.json',
      viewed: false
    };
    this.store.save(entry);
    this.store.setFlag(id);
  }

  // 收集当前设备信息
  collectDeviceInfo(): CrashDeviceInfo {
    try {
      const info: CrashDeviceInfo = {
        deviceModel: deviceInfo.marketName || deviceInfo.productModel || 'Unknown',
        osVersion: deviceInfo.osFullName || 'HarmonyOS',
        appVersion: this.getAppVersion()
      };
      return info;
    } catch (_e) {
      const info: CrashDeviceInfo = {
        deviceModel: 'Unknown',
        osVersion: 'HarmonyOS',
        appVersion: '0.0.0'
      };
      return info;
    }
  }

  // 缓存应用版本号，首次读取后不再重复查询
  private appVersion: string = '';
  private getAppVersion(): string {
    if (this.appVersion.length > 0) {
      return this.appVersion;
    }
    try {
      const ctx = this.context;
      const info = ctx.applicationInfo;
      this.appVersion = ((info as Object) as Record<string, string>)['versionName'] as string || '1.0.0';
    } catch (_e) {
      this.appVersion = '1.0.0';
    }
    return this.appVersion;
  }

  private formatTimestamp(ms: number): string {
    const d = new Date(ms);
    const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
    return d.getFullYear().toString() +
      pad(d.getMonth() + 1) + pad(d.getDate()) + '_' +
      pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
  }

  private truncate(s: string, max: number): string {
    if (!s) {
      return '';
    }
    // 取第一行截断
    const firstLine = s.split('\n')[0];
    return firstLine.length > max ? firstLine.substring(0, max) + '...' : firstLine;
  }
}
