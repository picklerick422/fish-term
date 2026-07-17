// CrashLogPanel.ets — 崩溃详情弹窗（启动时显示上次崩溃）

import { pasteboard } from '@kit.BasicServicesKit';
import { CrashType, CrashLogEntry } from '../crash/CrashTypes';
import { UiTheme, REFINED_DARK_THEME, RADIUS_CONTROL, RADIUS_SHEET } from '../theme/UiTheme';

function typeLabel(t: CrashType): string {
  switch (t) {
    case CrashType.JS_CRASH: return 'JS 崩溃';
    case CrashType.UNHANDLED_REJECTION: return '未处理的 Promise';
    case CrashType.NATIVE_SIGNAL: return 'Native 信号';
    case CrashType.CPP_CRASH: return 'C++ 崩溃';
    case CrashType.APP_FREEZE: return '应用冻结';
    default: return '未知';
  }
}

function formatTime(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

@Component
export struct CrashLogPanel {
  @Prop entry: CrashLogEntry = {
    id: '', timestamp: 0, crashType: CrashType.JS_CRASH,
    summary: '', stackTrace: '', systemLog: '',
    deviceInfo: { deviceModel: '', osVersion: '', appVersion: '' },
    logFileName: '', viewed: false
  };
  onClose: () => void = () => {};
  onViewed: (id: string) => void = (_id: string) => {};
  onDontShowAgain: () => void = () => {};

  @State private copyContentLabel: string = '复制日志内容';
  @State private copyPathLabel: string = '复制文件路径';
  @State private isStackExpanded: boolean = false;
  @State private isSysLogExpanded: boolean = false;
  @State private dontShowAgain: boolean = false;

  // Hover states
  @State private hoverExpandStack: boolean = false;
  @State private hoverExpandSysLog: boolean = false;
  @State private hoverCopyContent: boolean = false;
  @State private hoverCopyPath: boolean = false;
  @State private hoverClose: boolean = false;
  @State private hoverDontShow: boolean = false;
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  // Theme-token-backed crash type color (member method so it can read uiTheme).
  private typeColor(t: CrashType): string {
    switch (t) {
      case CrashType.JS_CRASH:
      case CrashType.UNHANDLED_REJECTION:
        return this.uiTheme.accent;
      case CrashType.NATIVE_SIGNAL:
      case CrashType.CPP_CRASH:
        return this.uiTheme.danger;
      case CrashType.APP_FREEZE:
        return this.uiTheme.warn;
      default:
        return this.uiTheme.textDim;
    }
  }

  aboutToAppear(): void {
    if (this.entry.viewed === false && this.entry.id.length > 0) {
      this.onViewed(this.entry.id);
    }
  }

  build() {
    Column() {
      // 标题栏 — 崩溃类型色标 + 标题文字
      Row({ space: 10 }) {
        // 类型色标圆点
        Circle({ width: 10, height: 10 })
          .fill(this.typeColor(this.entry.crashType))
        Column({ space: 2 }) {
          Text('应用上次发生了崩溃')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.uiTheme.textPrimary)
          Text(typeLabel(this.entry.crashType) + ' · ' + formatTime(this.entry.timestamp))
            .fontSize(12)
            .fontColor(this.uiTheme.textDim)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 22, left: 24, right: 24, bottom: 8 })

      // 分割线
      Divider()
        .color(this.uiTheme.border)
        .width('100%')
        .margin({ left: 24, right: 24 })

      // 滚动内容区
      Scroll() {
        Column({ space: 14 }) {
          this.buildCrashInfoBlock()

          if (this.entry.stackTrace.trim().length > 0) {
            this.buildStackBlock()
          }

          if (this.entry.systemLog.trim().length > 0) {
            this.buildSysLogBlock()
          }

          this.buildDeviceBlock()
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // 下次不再显示
      this.buildDontShowToggle()

      this.buildBottomButtons()
    }
    .width('100%')
    // Unified sheet shell (Task 8): bgSurface card + sheet radius + 1px border + shadow.
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_SHEET)
    .border({ width: 1, color: this.uiTheme.border })
    .shadow({ radius: 32, color: this.uiTheme.shadowCard, offsetX: 0, offsetY: 8 })
  }

  // === 崩溃信息 ===

  @Builder
  private buildCrashInfoBlock() {
    Column({ space: 10 }) {
      this.buildSectionHeader('●', '崩溃信息', this.typeColor(this.entry.crashType))
      Column({ space: 8 }) {
        this.buildInfoRow('类型', typeLabel(this.entry.crashType), this.typeColor(this.entry.crashType));
        this.buildInfoRow('时间', formatTime(this.entry.timestamp), this.uiTheme.textPrimary);
        this.buildInfoRow('摘要', this.entry.summary, this.uiTheme.textPrimary);
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CONTROL)
    .border({ width: 1, color: this.uiTheme.border })
    .alignItems(HorizontalAlign.Start)
  }

  // === 调用栈（可展开/收起） ===

  @Builder
  private buildStackBlock() {
    Column({ space: 10 }) {
      this.buildSectionHeader('▎', '调用栈', this.uiTheme.accent)

      Column() {
        Text(this.entry.stackTrace)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(this.uiTheme.textDim)
          .width('100%')
          .maxLines(this.isStackExpanded ? 999 : 15)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(10)
      .backgroundColor(this.uiTheme.bgInput)
      .borderRadius(6)

      if (this.entry.stackTrace.length > 600) {
        Row() {
          Text(this.isStackExpanded ? '收起 ▲' : '展开全部 ▼')
            .fontSize(11)
            .fontColor(this.hoverExpandStack ? this.uiTheme.accentHover : this.uiTheme.accent)
            .padding({ top: 2, bottom: 2, left: 8, right: 8 })
        }
        .borderRadius(4)
        .backgroundColor(this.hoverExpandStack ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverExpandStack = h; })
        .onClick(() => { this.isStackExpanded = !this.isStackExpanded; })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CONTROL)
    .border({ width: 1, color: this.uiTheme.border })
    .alignItems(HorizontalAlign.Start)
  }

  // === 系统日志（可展开/收起） ===

  @Builder
  private buildSysLogBlock() {
    Column({ space: 10 }) {
      this.buildSectionHeader('▎', '系统日志', this.uiTheme.warn)

      Column() {
        Text(this.entry.systemLog)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(this.uiTheme.textDim)
          .width('100%')
          .maxLines(this.isSysLogExpanded ? 999 : 8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(10)
      .backgroundColor(this.uiTheme.bgInput)
      .borderRadius(6)

      if (this.entry.systemLog.length > 400) {
        Row() {
          Text(this.isSysLogExpanded ? '收起 ▲' : '展开全部 ▼')
            .fontSize(11)
            .fontColor(this.hoverExpandSysLog ? this.uiTheme.accentHover : this.uiTheme.accent)
            .padding({ top: 2, bottom: 2, left: 8, right: 8 })
        }
        .borderRadius(4)
        .backgroundColor(this.hoverExpandSysLog ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverExpandSysLog = h; })
        .onClick(() => { this.isSysLogExpanded = !this.isSysLogExpanded; })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CONTROL)
    .border({ width: 1, color: this.uiTheme.border })
    .alignItems(HorizontalAlign.Start)
  }

  // === 设备信息 ===

  @Builder
  private buildDeviceBlock() {
    Column({ space: 10 }) {
      this.buildSectionHeader('●', '设备信息', this.uiTheme.textDim)
      Column({ space: 8 }) {
        this.buildInfoRow('设备', this.entry.deviceInfo.deviceModel, this.uiTheme.textPrimary);
        this.buildInfoRow('系统', this.entry.deviceInfo.osVersion, this.uiTheme.textPrimary);
        this.buildInfoRow('应用', this.entry.deviceInfo.appVersion, this.uiTheme.textPrimary);
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CONTROL)
    .border({ width: 1, color: this.uiTheme.border })
    .alignItems(HorizontalAlign.Start)
  }

  // === 下次不再显示 ===

  @Builder
  private buildDontShowToggle() {
    Row({ space: 8 }) {
      Text(this.dontShowAgain ? '◉' : '○')
        .fontSize(16)
        .fontColor(this.dontShowAgain ? this.uiTheme.accent : this.uiTheme.textDim)
      Text('下次不再显示')
        .fontSize(13)
        .fontColor(this.hoverDontShow ? this.uiTheme.textPrimary : this.uiTheme.textDim)
    }
    .padding({ top: 4, bottom: 4, left: 6, right: 6 })
    .borderRadius(4)
    .backgroundColor(this.hoverDontShow ? this.uiTheme.pressOverlay : Color.Transparent)
    .animation({ duration: 120, curve: Curve.EaseOut })
    .focusable(false)
    .onHover((h: boolean) => { this.hoverDontShow = h; })
    .onClick(() => { this.dontShowAgain = !this.dontShowAgain; })
  }

  // === 底部按钮 ===

  @Builder
  private buildBottomButtons() {
    Column({ space: 10 }) {
      // 复制日志内容
      Row() {
        Text(this.copyContentLabel)
          .fontSize(14)
          .fontColor(this.hoverCopyContent ? this.uiTheme.accentHover : this.uiTheme.accent)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.hoverCopyContent ? this.uiTheme.bgElevated : this.uiTheme.bgSurface)
      .borderRadius(RADIUS_CONTROL)
      .border({ width: 1, color: this.uiTheme.accent })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverCopyContent = h; })
      .onClick(() => { this.doCopyContent(); })

      // 复制文件路径
      Row() {
        Text(this.copyPathLabel)
          .fontSize(14)
          .fontColor(this.hoverCopyPath ? this.uiTheme.textPrimary : this.uiTheme.textDim)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.hoverCopyPath ? this.uiTheme.bgElevated : this.uiTheme.bgSurface)
      .borderRadius(RADIUS_CONTROL)
      .border({ width: 1, color: this.hoverCopyPath ? this.uiTheme.textDim : this.uiTheme.border })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverCopyPath = h; })
      .onClick(() => { this.doCopyPath(); })

      // "我知道了"
      Button('我知道了')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(this.uiTheme.bgBase)
        .backgroundColor(this.hoverClose ? this.uiTheme.accentHover : this.uiTheme.accent)
        .borderRadius(RADIUS_CONTROL)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onHover((h: boolean) => { this.hoverClose = h; })
        .onClick(() => {
          if (this.dontShowAgain) {
            this.onDontShowAgain();
          }
          this.onViewed(this.entry.id);
          this.onClose();
        })
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 24 })
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
  private buildInfoRow(label: string, value: string, valueColor: string) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(12)
        .fontColor(this.uiTheme.textDim)
        .width(48)
      Text(value)
        .fontSize(12)
        .fontColor(valueColor)
        .layoutWeight(1)
    }
    .width('100%')
  }

  // === 复制操作 ===

  private doCopyContent(): void {
    const text = this.buildFullLogText();
    this.copyToClipboard(text);
    this.copyContentLabel = '已复制';
    setTimeout(() => { this.copyContentLabel = '复制日志内容'; }, 2000);
  }

  private doCopyPath(): void {
    const path = '(应用沙箱)/crash_logs/' + this.entry.logFileName;
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

  private buildFullLogText(): string {
    const lines: string[] = [];
    lines.push('=== fish-term 崩溃日志 ===');
    lines.push('类型: ' + typeLabel(this.entry.crashType));
    lines.push('时间: ' + formatTime(this.entry.timestamp));
    lines.push('摘要: ' + this.entry.summary);
    lines.push('');
    lines.push('--- 调用栈 ---');
    lines.push(this.entry.stackTrace);
    if (this.entry.systemLog.trim().length > 0) {
      lines.push('');
      lines.push('--- 系统日志 ---');
      lines.push(this.entry.systemLog);
    }
    lines.push('');
    lines.push('--- 设备信息 ---');
    lines.push('设备: ' + this.entry.deviceInfo.deviceModel);
    lines.push('系统: ' + this.entry.deviceInfo.osVersion);
    lines.push('应用: ' + this.entry.deviceInfo.appVersion);
    return lines.join('\n');
  }
}
