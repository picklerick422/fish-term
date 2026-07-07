// CrashTypes.ets — 崩溃日志数据模型

export enum CrashType {
  JS_CRASH = 'js_crash',
  UNHANDLED_REJECTION = 'unhandled_rejection',
  NATIVE_SIGNAL = 'native_signal',
  CPP_CRASH = 'cpp_crash',
  APP_FREEZE = 'app_freeze',
}

export interface CrashLogEntry {
  id: string;
  timestamp: number;
  crashType: CrashType;
  summary: string;
  stackTrace: string;
  systemLog: string;
  deviceInfo: CrashDeviceInfo;
  logFileName: string;
  viewed: boolean;
}

export interface CrashDeviceInfo {
  deviceModel: string;
  osVersion: string;
  appVersion: string;
}

// Internal use — file listing entry
export interface FileEntry {
  name: string;
  mtime: number;
}
