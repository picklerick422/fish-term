// CrashHistoryPage.ets — 历史崩溃列表

import { pasteboard } from '@kit.BasicServicesKit';
import { CrashType, CrashLogEntry } from '../crash/CrashTypes';
import { CrashStore } from '../crash/CrashStore';
import { Palette } from '../theme/Palette';

function typeLabel(t: CrashType): string {
  switch (t) {
    case CrashType.JS_CRASH: return 'JS 崩溃';
    case CrashType.UNHANDLED_REJECTION: return 'Promise 异常';
    case CrashType.NATIVE_SIGNAL: return 'Native 信号';
    case CrashType.CPP_CRASH: return 'C++ 崩溃';
    case CrashType.APP_FREEZE: return '系统冻结';
    default: return '未知';
  }
}

function typeColor(t: CrashType): string {
  switch (t) {
    case CrashType.JS_CRASH:
    case CrashType.UNHANDLED_REJECTION:
      return Palette.accent;
    case CrashType.NATIVE_SIGNAL:
    case CrashType.CPP_CRASH:
      return Palette.danger;
    case CrashType.APP_FREEZE:
      return Palette.warn;
    default:
      return Palette.textDim;
  }
}

function typeDotColor(t: CrashType): string {
  switch (t) {
    case CrashType.JS_CRASH:
    case CrashType.UNHANDLED_REJECTION:
      return Palette.accent;
    case CrashType.NATIVE_SIGNAL:
    case CrashType.CPP_CRASH:
      return Palette.danger;
    case CrashType.APP_FREEZE:
      return Palette.warn;
    default:
      return Palette.textDim;
  }
}

function formatDate(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function formatFullTime(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

@Component
export struct CrashHistoryPage {
  @Prop entries: CrashLogEntry[] = [];
  onBack: () => void = () => {};
  onDeleteAll: () => void = () => {};
  store: CrashStore | null = null;

  @State private selectedEntry: CrashLogEntry | null = null;
  @State private copyContentLabel: string = '复制日志内容';
  @State private copyPathLabel: string = '复制文件路径';
  @State private isStackExpanded: boolean = false;
  @State private isSysLogExpanded: boolean = false;
  private tabsController: TabsController = new TabsController();

  // Hover states
  @State private hoverBack: boolean = false;
  @State private hoverItemId: string = '';
  @State private hoverDeleteAll: boolean = false;
  @State private hoverExpandStack: boolean = false;
  @State private hoverExpandSysLog: boolean = false;
  @State private hoverCopyContent: boolean = false;
  @State private hoverCopyPath: boolean = false;

  build() {
    Column() {
      Tabs({ controller: this.tabsController, index: this.selectedEntry !== null ? 1 : 0 }) {
        TabContent() {
          this.buildListView()
        }
        TabContent() {
          if (this.selectedEntry !== null) {
            this.buildDetailView()
          }
        }
      }
      .barHeight(0)
      .scrollable(false)
      .animationDuration(280)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
  }

  // ==================== 列表视图 ====================

  @Builder
  private buildListView() {
    Column() {
      // Header
      Row() {
        Row() {
          Text('←')
            .fontSize(18)
            .fontColor(Palette.textDim)
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.hoverBack ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverBack = h; })
        .onClick(() => { this.onBack(); })

        Text('崩溃历史')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)

        Blank()
        Row().width(40).height(1)
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.entries.length === 0) {
        Column({ space: 12 }) {
          Text('·')
            .fontSize(40)
            .fontColor(Palette.textDim)
          Text('暂无崩溃记录')
            .fontSize(14)
            .fontColor(Palette.textDim)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.entries, (entry: CrashLogEntry, index: number) => {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Circle({ width: 8, height: 8 })
                    .fill(typeDotColor(entry.crashType))
                  Text(typeLabel(entry.crashType))
                    .fontSize(12)
                    .fontColor(typeColor(entry.crashType))
                  Text(formatDate(entry.timestamp))
                    .fontSize(11)
                    .fontColor(Palette.textDim)
                  Blank()
                  Text('›')
                    .fontSize(16)
                    .fontColor(Palette.textDim)
                }
                .width('100%')

                Text(entry.summary)
                  .fontSize(12)
                  .fontColor(Palette.textDim)
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.hoverItemId === entry.id ? '#1A1F2A' : Palette.surface)
              .borderRadius(8)
              .border({ width: 1, color: this.hoverItemId === entry.id ? Palette.accent : Palette.border })
              .animation({ duration: 150, curve: Curve.EaseOut })
              .focusable(false)
              .onHover((h: boolean) => { this.hoverItemId = h ? entry.id : ''; })
              .onClick(() => {
                this.selectedEntry = entry;
                this.isStackExpanded = false;
                this.isSysLogExpanded = false;
                this.tabsController.changeIndex(1);
              })
            }, (entry: CrashLogEntry) => entry.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Row() {
          Text('清空全部记录')
            .fontSize(14)
            .fontColor(this.hoverDeleteAll ? '#FF8A8A' : Palette.danger)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.hoverDeleteAll ? '#1A1F2A' : Color.Transparent)
        .borderRadius(8)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverDeleteAll = h; })
        .onClick(() => {
          if (this.store) {
            this.store.deleteAll();
          }
          this.onDeleteAll();
        })
        .padding({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 详情视图 ====================

  @Builder
  private buildDetailView() {
    Column({ space: 16 }) {
      Row() {
        Row() {
          Text('←')
            .fontSize(18)
            .fontColor(Palette.textDim)
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.hoverBack ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverBack = h; })
        .onClick(() => {
          this.selectedEntry = null;
          this.isStackExpanded = false;
          this.isSysLogExpanded = false;
          this.tabsController.changeIndex(0);
        })

        Text('崩溃详情')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)

        Blank()
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })

      Scroll() {
        Column({ space: 14 }) {
          this.buildCrashInfoSection()

          if (this.selectedEntry !== null && this.selectedEntry.stackTrace.trim().length > 0) {
            this.buildStackSection()
          }

          if (this.selectedEntry !== null && this.selectedEntry.systemLog.trim().length > 0) {
            this.buildSysLogSection()
          }

          this.buildDeviceSection()
          this.buildCopyButtons()
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
  }

  // ---- 崩溃信息 ----

  @Builder
  private buildCrashInfoSection() {
    Column({ space: 10 }) {
      this.buildSectionHeader('●', '崩溃信息', typeColor(this.selectedEntry!.crashType))
      Column({ space: 8 }) {
        this.buildDetailRow('类型', typeLabel(this.selectedEntry!.crashType), typeColor(this.selectedEntry!.crashType));
        this.buildDetailRow('时间', formatFullTime(this.selectedEntry!.timestamp), Palette.text);
        this.buildDetailRow('摘要', this.selectedEntry!.summary, Palette.text);
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.surface)
    .borderRadius(8)
    .border({ width: 1, color: Palette.border })
    .alignItems(HorizontalAlign.Start)
  }

  // ---- 调用栈（可展开/收起） ----

  @Builder
  private buildStackSection() {
    Column({ space: 10 }) {
      this.buildSectionHeader('▎', '调用栈', Palette.accent)

      Column() {
        Text(this.selectedEntry!.stackTrace)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(Palette.textDim)
          .width('100%')
          .maxLines(this.isStackExpanded ? 999 : 15)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#080C12')
      .borderRadius(6)

      if (this.selectedEntry!.stackTrace.length > 600) {
        Row() {
          Text(this.isStackExpanded ? '收起 ▲' : '展开全部 ▼')
            .fontSize(11)
            .fontColor(this.hoverExpandStack ? '#5FE8D8' : Palette.accent)
            .padding({ top: 2, bottom: 2, left: 8, right: 8 })
        }
        .borderRadius(4)
        .backgroundColor(this.hoverExpandStack ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverExpandStack = h; })
        .onClick(() => { this.isStackExpanded = !this.isStackExpanded; })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.surface)
    .borderRadius(8)
    .border({ width: 1, color: Palette.border })
    .alignItems(HorizontalAlign.Start)
  }

  // ---- 系统日志（可展开/收起） ----

  @Builder
  private buildSysLogSection() {
    Column({ space: 10 }) {
      this.buildSectionHeader('▎', '系统日志', Palette.warn)

      Column() {
        Text(this.selectedEntry!.systemLog)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(Palette.textDim)
          .width('100%')
          .maxLines(this.isSysLogExpanded ? 999 : 8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#080C12')
      .borderRadius(6)

      if (this.selectedEntry!.systemLog.length > 400) {
        Row() {
          Text(this.isSysLogExpanded ? '收起 ▲' : '展开全部 ▼')
            .fontSize(11)
            .fontColor(this.hoverExpandSysLog ? '#5FE8D8' : Palette.accent)
            .padding({ top: 2, bottom: 2, left: 8, right: 8 })
        }
        .borderRadius(4)
        .backgroundColor(this.hoverExpandSysLog ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverExpandSysLog = h; })
        .onClick(() => { this.isSysLogExpanded = !this.isSysLogExpanded; })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.surface)
    .borderRadius(8)
    .border({ width: 1, color: Palette.border })
    .alignItems(HorizontalAlign.Start)
  }

  // ---- 设备信息 ----

  @Builder
  private buildDeviceSection() {
    Column({ space: 10 }) {
      this.buildSectionHeader('●', '设备信息', Palette.textDim)
      Column({ space: 8 }) {
        if (this.selectedEntry !== null) {
          this.buildDetailRow('设备', this.selectedEntry.deviceInfo.deviceModel, Palette.text);
          this.buildDetailRow('系统', this.selectedEntry.deviceInfo.osVersion, Palette.text);
          this.buildDetailRow('应用', this.selectedEntry.deviceInfo.appVersion, Palette.text);
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.surface)
    .borderRadius(8)
    .border({ width: 1, color: Palette.border })
    .alignItems(HorizontalAlign.Start)
  }

  // ---- 复制按钮 ----

  @Builder
  private buildCopyButtons() {
    Column({ space: 10 }) {
      Row() {
        Text(this.copyContentLabel)
          .fontSize(14)
          .fontColor(this.hoverCopyContent ? '#5FE8D8' : Palette.accent)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.hoverCopyContent ? '#1A1F2A' : Palette.surface)
      .borderRadius(8)
      .border({ width: 1, color: Palette.accent })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverCopyContent = h; })
      .onClick(() => { this.copyDetailContent(); })

      Row() {
        Text(this.copyPathLabel)
          .fontSize(14)
          .fontColor(this.hoverCopyPath ? Palette.text : Palette.textDim)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.hoverCopyPath ? '#1A1F2A' : Palette.surface)
      .borderRadius(8)
      .border({ width: 1, color: this.hoverCopyPath ? Palette.textDim : Palette.border })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverCopyPath = h; })
      .onClick(() => { this.copyDetailPath(); })
    }
    .width('100%')
    .padding({ top: 8 })
  }

  // === 通用组件 ===

  @Builder
  private buildSectionHeader(indicator: string, title: string, color: string) {
    Row({ space: 6 }) {
      Text(indicator)
        .fontSize(10)
        .fontColor(color)
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
        .opacity(0.9)
    }
    .width('100%')
  }

  @Builder
  private buildDetailRow(label: string, value: string, valueColor: string) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(12)
        .fontColor(Palette.textDim)
        .width(48)
      Text(value)
        .fontSize(12)
        .fontColor(valueColor)
        .layoutWeight(1)
    }
    .width('100%')
  }

  // === 复制操作 ===

  private copyDetailContent(): void {
    if (!this.selectedEntry) {
      return;
    }
    const e = this.selectedEntry;
    const lines: string[] = [];
    lines.push('=== fish-term 崩溃日志 ===');
    lines.push('类型: ' + typeLabel(e.crashType));
    lines.push('时间: ' + formatFullTime(e.timestamp));
    lines.push('摘要: ' + e.summary);
    lines.push('');
    lines.push('--- 调用栈 ---');
    lines.push(e.stackTrace);
    if (e.systemLog.trim().length > 0) {
      lines.push('');
      lines.push('--- 系统日志 ---');
      lines.push(e.systemLog);
    }
    lines.push('');
    lines.push('--- 设备信息 ---');
    lines.push('设备: ' + e.deviceInfo.deviceModel);
    lines.push('系统: ' + e.deviceInfo.osVersion);
    lines.push('应用: ' + e.deviceInfo.appVersion);
    const text = lines.join('\n');
    this.copyToClipboard(text);
    this.copyContentLabel = '已复制';
    setTimeout(() => { this.copyContentLabel = '复制日志内容'; }, 2000);
  }

  private copyDetailPath(): void {
    if (!this.selectedEntry) {
      return;
    }
    const path = '(应用沙箱)/crash_logs/' + this.selectedEntry.logFileName;
    this.copyToClipboard(path);
    this.copyPathLabel = '已复制';
    setTimeout(() => { this.copyPathLabel = '复制文件路径'; }, 2000);
  }

  private copyToClipboard(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const sysPb = pasteboard.getSystemPasteboard();
      sysPb.setData(data);
    } catch (_e) {
      // 静默失败
    }
  }
}
