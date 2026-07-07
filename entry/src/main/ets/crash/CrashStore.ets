// CrashStore.ets — 崩溃日志文件持久化，管理 crash_logs/ 目录

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { CrashLogEntry, CrashDeviceInfo, FileEntry, CrashType } from './CrashTypes';

const CRASH_DIR = 'crash_logs';
const FLAG_FILE = '.crash_flag';
const MAX_LOG_FILES = 20;

export class CrashStore {
  private readonly context: common.UIAbilityContext;
  private readonly baseDir: string;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.baseDir = this.context.filesDir + '/' + CRASH_DIR;
  }

  // 确保 crash_logs 目录存在，返回 false 表示存储不可用
  private ensureDir(): boolean {
    try {
      if (!fileIo.accessSync(this.baseDir)) {
        fileIo.mkdirSync(this.baseDir);
      }
      return true;
    } catch (_e) {
      console.error('CrashStore: failed to create crash_logs dir');
      return false;
    }
  }

  // 保存一条崩溃日志，返回是否成功
  save(entry: CrashLogEntry): boolean {
    if (!this.ensureDir()) {
      return false;
    }
    try {
      const path = this.baseDir + '/' + entry.logFileName;
      const json = JSON.stringify(entry, null, 2);
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, json);
      fileIo.closeSync(file);
      this.pruneIfNeeded();
      return true;
    } catch (e) {
      // 降级：尝试写纯文本
      try {
        const fallbackPath = this.baseDir + '/' + entry.logFileName.replace('.json', '.log');
        const fb = fileIo.openSync(fallbackPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        const text = `${entry.crashType}\n${entry.timestamp}\n${entry.summary}\n${entry.stackTrace}\n${entry.systemLog}`;
        fileIo.writeSync(fb.fd, text);
        fileIo.closeSync(fb);
        entry.logFileName = fallbackPath.substring(fallbackPath.lastIndexOf('/') + 1);
        return true;
      } catch (_e2) {
        console.error('CrashStore: failed to write fallback log');
        return false;
      }
    }
  }

  // 列出所有日志文件，按 mtime 降序（最新在前）
  listEntries(): CrashLogEntry[] {
    if (!this.ensureDir()) {
      return [];
    }
    const result: CrashLogEntry[] = [];
    try {
      const files = fileIo.listFileSync(this.baseDir);
      const entries: FileEntry[] = [];
      for (const f of files) {
        if (f.startsWith('.') || !f.endsWith('.json')) {
          continue;
        }
        try {
          const stat = fileIo.statSync(this.baseDir + '/' + f);
          const fe: FileEntry = { name: f, mtime: stat.mtime };
          entries.push(fe);
        } catch (_) {
          const fe: FileEntry = { name: f, mtime: 0 };
          entries.push(fe);
        }
      }
      // 按 mtime 降序
      entries.sort((a, b) => b.mtime - a.mtime);
      for (const e of entries) {
        try {
          const content = fileIo.readTextSync(this.baseDir + '/' + e.name);
          const entry: CrashLogEntry = JSON.parse(content) as CrashLogEntry;
          result.push(entry);
        } catch (_) {
          // 损坏文件跳过
        }
      }
    } catch (_e) {
      // 列表失败返回空
    }
    return result;
  }

  // 扫描 native 信号处理器写入的 .log 文件并创建 CrashLogEntry
  listNativeEntries(): CrashLogEntry[] {
    if (!this.ensureDir()) {
      return [];
    }
    const result: CrashLogEntry[] = [];
    try {
      const files = fileIo.listFileSync(this.baseDir);
      for (const f of files) {
        if (f.startsWith('native_') && f.endsWith('.log')) {
          try {
            const path = this.baseDir + '/' + f;
            const stat = fileIo.statSync(path);
            const content = fileIo.readTextSync(path);
            const id = 'native_' + stat.mtime;
            const devInfo: CrashDeviceInfo = { deviceModel: '', osVersion: '', appVersion: '' };
            const entry: CrashLogEntry = {
              id: id,
              timestamp: stat.mtime * 1000,
              crashType: CrashType.NATIVE_SIGNAL,
              summary: content.split('\n').slice(0, 3).join('; ').substring(0, 200),
              stackTrace: content,
              systemLog: '',
              deviceInfo: devInfo,
              logFileName: f,
              viewed: false
            };
            result.push(entry);
          } catch (_) {
            // skip broken file
          }
        }
      }
    } catch (_e) {
      // fail silently
    }
    return result;
  }

  // 标记某条记录为已查看
  markViewed(id: string): void {
    if (!this.ensureDir()) {
      return;
    }
    try {
      const files = fileIo.listFileSync(this.baseDir);
      for (const f of files) {
        if (!f.startsWith('.') && f.endsWith('.json')) {
          try {
            const path = this.baseDir + '/' + f;
            const content = fileIo.readTextSync(path);
            const entry: CrashLogEntry = JSON.parse(content) as CrashLogEntry;
            if (entry.id === id) {
              entry.viewed = true;
              const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY);
              fileIo.writeSync(file.fd, JSON.stringify(entry, null, 2));
              fileIo.closeSync(file);
              return;
            }
          } catch (_) {
            // skip broken file
          }
        }
      }
    } catch (_e) {
      // fail silently
    }
  }

  // 删除所有日志文件
  deleteAll(): void {
    if (!this.ensureDir()) {
      return;
    }
    try {
      const files = fileIo.listFileSync(this.baseDir);
      for (const f of files) {
        try {
          fileIo.unlinkSync(this.baseDir + '/' + f);
        } catch (_) {
          // skip
        }
      }
    } catch (_e) {
      // fail silently
    }
  }

  // 删除单条日志
  deleteById(id: string): void {
    if (!this.ensureDir()) {
      return;
    }
    try {
      const files = fileIo.listFileSync(this.baseDir);
      for (const f of files) {
        if (!f.startsWith('.') && f.endsWith('.json')) {
          try {
            const content = fileIo.readTextSync(this.baseDir + '/' + f);
            const entry: CrashLogEntry = JSON.parse(content) as CrashLogEntry;
            if (entry.id === id) {
              fileIo.unlinkSync(this.baseDir + '/' + f);
              return;
            }
          } catch (_) {
            // skip
          }
        }
      }
    } catch (_e) {
      // fail silently
    }
  }

  // ----- 标记文件 -----

  // 写入崩溃标记（内容为 crash id）
  setFlag(crashId: string): void {
    if (!this.ensureDir()) {
      return;
    }
    try {
      const path = this.baseDir + '/' + FLAG_FILE;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, crashId);
      fileIo.closeSync(file);
    } catch (_e) {
      // fail silently
    }
  }

  // 读取标记文件，返回 crash id 或 null
  getFlag(): string | null {
    try {
      const path = this.baseDir + '/' + FLAG_FILE;
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const content = fileIo.readTextSync(path);
      return content.trim().length > 0 ? content.trim() : null;
    } catch (_e) {
      return null;
    }
  }

  // 删除标记文件（正常退出时调用）
  clearFlag(): void {
    try {
      const path = this.baseDir + '/' + FLAG_FILE;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_e) {
      // fail silently
    }
  }

  // 删除超出 MAX_LOG_FILES 的最旧文件
  private pruneIfNeeded(): void {
    try {
      const files = fileIo.listFileSync(this.baseDir);
      const jsonFiles = files.filter((f: string) => f.endsWith('.json') && !f.startsWith('.'));
      if (jsonFiles.length <= MAX_LOG_FILES) {
        return;
      }
      const withMtime: FileEntry[] = [];
      for (const f of jsonFiles) {
        try {
          const stat = fileIo.statSync(this.baseDir + '/' + f);
          const fe: FileEntry = { name: f, mtime: stat.mtime };
          withMtime.push(fe);
        } catch (_) {
          const fe: FileEntry = { name: f, mtime: 0 };
          withMtime.push(fe);
        }
      }
      withMtime.sort((a, b) => a.mtime - b.mtime);
      const toDelete = withMtime.slice(0, withMtime.length - MAX_LOG_FILES);
      for (const d of toDelete) {
        try {
          fileIo.unlinkSync(this.baseDir + '/' + d.name);
        } catch (_) {
          // skip
        }
      }
    } catch (_e) {
      // fail silently
    }
  }
}
