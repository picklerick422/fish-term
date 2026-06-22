import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { TerminalController, TerminalSurface } from 'libghostty_ohos';
import { TerminalSession } from '../session/TerminalSession';
import { FishWebSocketDriver } from '../transport/FishWebSocketDriver';
import { DriverState, DriverStatus, FishConnectConfig } from '../transport/TerminalDriver';
import { ConnectionStore, ConnectionProfile, TerminalPrefs, DEFAULT_TERMINAL_PREFS } from '../store/ConnectionStore';
import { Palette } from '../theme/Palette';
import { DEFAULT_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE, stepFontSize, clampFontSize } from '../theme/FontScale';
import { SettingsPanel } from './SettingsPanel';

function stateLabel(s: DriverStatus): string {
  switch (s.state) {
    case DriverState.Connecting:
      return '连接中…';
    case DriverState.Connected:
      return '已连接';
    case DriverState.Reconnecting:
      return '重连中…';
    case DriverState.Closed:
      return '已断开';
    case DriverState.Error:
      return '错误：' + (s.message ?? '');
    default:
      return '空闲';
  }
}

@Entry
@Component
struct Index {
  // Controller + XComponent surface live for the whole page lifetime (see
  // terminalsurface-lifecycle memory). Connect/disconnect only start/stop the driver.
  // CRITICAL (focus model): the terminal XComponent must own keyboard focus — it
  // receives keys/scroll natively only while focused. Any other focusable control
  // (the status-bar buttons) would let ArkUI's Tab/arrow focus navigation swallow
  // keys the TUI needs, so those controls are .focusable(false) and every tap hands
  // focus straight back to the terminal via focusTerminal().
  private readonly surfaceId: string = 'fishTermSurface';
  private controller: TerminalController = new TerminalController();
  private session: TerminalSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private store: ConnectionStore | null = null;

  @State private connected: boolean = false;
  @State private host: string = '192.168.1.10';
  @State private port: string = '8765';
  @State private token: string = '';
  @State private tls: boolean = false;
  @State private rememberToken: boolean = false;
  @State private showToken: boolean = false;
  @State private fontSize: number = DEFAULT_FONT_SIZE;
  @State private statusText: string = '空闲';
  @State private driverState: DriverState = DriverState.Idle;
  @State private formError: string = '';
  @State private focusedField: string = '';
  @State private showSettings: boolean = false;
  @State private themeName: string = 'Aizen_Dark';
  @State private cursorStyle: number = 0;
  @State private cursorBlink: boolean = true;
  @State private scrollbackLines: number = 20000;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new ConnectionStore(this.context);
    this.loadProfile();
    this.loadSettings();
    emitter.on({ eventId: 10086 }, () => {
      this.session?.onForeground();
    });
  }

  private loadProfile(): void {
    const store: ConnectionStore | null = this.store;
    if (!store) {
      return;
    }
    store.load().then((p: ConnectionProfile): void => {
      this.host = p.host;
      this.port = p.port;
      this.tls = p.tls;
      this.rememberToken = p.rememberToken;
      this.token = p.token;
    });
  }

  private loadSettings(): void {
    const store: ConnectionStore | null = this.store;
    if (!store) {
      this.controller.updateConfig({
        fontSize: this.fontSize,
        scrollbackLines: this.scrollbackLines,
        cursorStyle: this.cursorStyle,
        cursorBlink: this.cursorBlink
      });
      return;
    }
    store.loadFontSize(DEFAULT_FONT_SIZE).then((fs: number): void => {
      this.fontSize = clampFontSize(fs);
    });
    store.loadTheme('Aizen_Dark').then((name: string): void => {
      this.themeName = name;
      this.controller.setTheme(name);
    });
    store.loadTerminalPrefs(DEFAULT_TERMINAL_PREFS).then((prefs: TerminalPrefs): void => {
      this.cursorStyle = prefs.cursorStyle;
      this.cursorBlink = prefs.cursorBlink;
      this.scrollbackLines = prefs.scrollbackLines;
      this.controller.updateConfig({
        fontSize: this.fontSize,
        scrollbackLines: prefs.scrollbackLines,
        cursorStyle: prefs.cursorStyle,
        cursorBlink: prefs.cursorBlink
      });
    });
  }

  aboutToDisappear(): void {
    emitter.off(10086);
    this.stopSession();
  }

  // Hand keyboard focus back to the terminal so keys/scroll keep reaching it.
  private focusTerminal(): void {
    setTimeout(() => {
      focusControl.requestFocus(this.surfaceId);
    }, 0);
  }

  private connect(): void {
    const host: string = this.host.trim();
    const token: string = this.token.trim();
    const port: number = Number(this.port);
    if (host.length === 0) {
      this.formError = '请输入主机地址';
      return;
    }
    if (!Number.isInteger(port) || port <= 0 || port > 65535) {
      this.formError = '端口无效（1-65535）';
      return;
    }
    if (token.length === 0) {
      this.formError = '请输入 token';
      return;
    }
    this.formError = '';

    if (this.store) {
      const profile: ConnectionProfile = {
        host,
        port: this.port.trim(),
        tls: this.tls,
        rememberToken: this.rememberToken,
        token
      };
      this.store.save(profile);
    }

    this.stopSession();

    const cfg: FishConnectConfig = { host, port, token, tls: this.tls };
    const session: TerminalSession = new TerminalSession(this.controller, new FishWebSocketDriver(cfg));
    session.onStatus((s: DriverStatus): void => {
      this.statusText = stateLabel(s);
      this.driverState = s.state;
    });
    this.session = session;
    this.statusText = '连接中…';
    this.driverState = DriverState.Connecting;
    this.connected = true;
    session.start();
    this.focusTerminal();
  }

  private disconnect(): void {
    this.stopSession();
    this.connected = false;
    this.statusText = '空闲';
    this.driverState = DriverState.Idle;
  }

  private stopSession(): void {
    if (this.session) {
      this.session.stop();
      this.session = null;
    }
  }

  private applyFontSize(size: number): void {
    this.fontSize = size;
    this.controller.updateConfig({ fontSize: size });
    if (this.store) {
      this.store.saveFontSize(size);
    }
  }

  private adjustFont(deltaSteps: number): void {
    this.applyFontSize(stepFontSize(this.fontSize, deltaSteps));
    this.focusTerminal();
  }

  private dotColor(): string {
    switch (this.driverState) {
      case DriverState.Connected:
        return Palette.accent;
      case DriverState.Connecting:
      case DriverState.Reconnecting:
        return Palette.warn;
      case DriverState.Error:
        return Palette.danger;
      default:
        return Palette.textDim;
    }
  }

  build() {
    Stack() {
      Column() {
        if (this.connected) {
          this.buildStatusBar();
        }
        TerminalSurface({
          controller: this.controller,
          surfaceId: this.surfaceId,
          surfaceColor: Palette.base
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.showSettings, this.buildSettingsSheet(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: true,
        backgroundColor: Palette.base,
        onDisappear: () => { this.focusTerminal(); }
      })

      if (!this.connected) {
        this.buildForm();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
  }

  @Builder
  private buildSettingsSheet() {
    SettingsPanel({
      controller: this.controller,
      store: this.store,
      fontSize: this.fontSize,
      themeName: $$this.themeName,
      cursorStyle: $$this.cursorStyle,
      cursorBlink: $$this.cursorBlink,
      scrollbackLines: $$this.scrollbackLines,
      onFontSizeChange: (s: number) => { this.applyFontSize(s); },
      onClose: () => { this.showSettings = false; }
    })
  }

  @Builder
  private buildStatusBar() {
    Row({ space: 12 }) {
      // status group: colored dot + label
      Row({ space: 7 }) {
        Text('●')
          .fontSize(10)
          .fontColor(this.dotColor())
        Text(this.statusText)
          .fontSize(13)
          .fontColor(Palette.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(this.host + ':' + this.port)
        .layoutWeight(1)
        .fontSize(12)
        .fontColor(Palette.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // font-size pill (mouse-only, never steals keyboard focus)
      Row({ space: 2 }) {
        Row() {
          Text('A-')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.fontSize <= MIN_FONT_SIZE ? '#4A5568' : '#3DD6C4')
        }
        .width(32)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1520')
        .borderRadius(8)
        .focusable(false)
        .enabled(this.fontSize > MIN_FONT_SIZE)
        .onClick(() => {
          if (this.fontSize > MIN_FONT_SIZE) {
            this.adjustFont(-1);
          }
        })

        Text(this.fontSize.toString())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#3DD6C4')
          .width(26)
          .textAlign(TextAlign.Center)

        Row() {
          Text('A+')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.fontSize >= MAX_FONT_SIZE ? '#4A5568' : '#3DD6C4')
        }
        .width(32)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1520')
        .borderRadius(8)
        .focusable(false)
        .enabled(this.fontSize < MAX_FONT_SIZE)
        .onClick(() => {
          if (this.fontSize < MAX_FONT_SIZE) {
            this.adjustFont(1);
          }
        })
      }
      .padding({ left: 3, right: 3, top: 2, bottom: 2 })
      .backgroundColor('#080F18')
      .borderRadius(16)
      .border({ width: 1, color: '#1E2630' })

      // settings gear button
      Row() {
        Text('⚙')
          .fontSize(16)
          .fontColor(Palette.textDim)
      }
      .width(32)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#0D1520')
      .borderRadius(8)
      .focusable(false)
      .onClick(() => { this.showSettings = true; })

      Button('断开')
        .type(ButtonType.Normal)
        .height(28)
        .fontSize(13)
        .focusable(false)
        .backgroundColor(Color.Transparent)
        .fontColor(Palette.danger)
        .borderWidth(1)
        .borderColor(Palette.danger)
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.disconnect();
        })
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Palette.surface)
    .border({ width: { bottom: 1 }, color: Palette.border })
  }

  @Builder
  private buildForm() {
    Column() {
      Column({ space: 6 }) {
        Text('◐ fish-term')
          .fontSize(26)
          .fontColor(Palette.text)
        Text('connect to fish-agent')
          .fontSize(13)
          .fontColor(Palette.textDim)
      }
      .margin({ bottom: 20 })

      Column({ space: 14 }) {
        Row({ space: 10 }) {
          TextInput({ text: this.host, placeholder: '主机 host' })
            .layoutWeight(2)
            .height(44)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'host' ? Palette.accent : Palette.border)
            .onFocus(() => {
              this.focusedField = 'host';
            })
            .onBlur(() => {
              if (this.focusedField === 'host') {
                this.focusedField = '';
              }
            })
            .onChange((v: string) => {
              this.host = v;
            })
            .onSubmit(() => {
              this.connect();
            })
          TextInput({ text: this.port, placeholder: '端口' })
            .layoutWeight(1)
            .height(44)
            .type(InputType.Number)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'port' ? Palette.accent : Palette.border)
            .onFocus(() => {
              this.focusedField = 'port';
            })
            .onBlur(() => {
              if (this.focusedField === 'port') {
                this.focusedField = '';
              }
            })
            .onChange((v: string) => {
              this.port = v;
            })
            .onSubmit(() => {
              this.connect();
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          TextInput({ text: this.token, placeholder: 'token' })
            .layoutWeight(1)
            .height(44)
            .type(this.showToken ? InputType.Normal : InputType.Password)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'token' ? Palette.accent : Palette.border)
            .onFocus(() => {
              this.focusedField = 'token';
            })
            .onBlur(() => {
              if (this.focusedField === 'token') {
                this.focusedField = '';
              }
            })
            .onChange((v: string) => {
              this.token = v;
            })
            .onSubmit(() => {
              this.connect();
            })
          Button(this.showToken ? '隐藏' : '显示')
            .height(44)
            .width(56)
            .fontSize(13)
            .backgroundColor(Palette.inputBg)
            .fontColor(Palette.textDim)
            .borderRadius(8)
            .onClick(() => {
              this.showToken = !this.showToken;
            })
        }
        .width('100%')

        Row() {
          Text('TLS (wss)')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.tls })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => {
              this.tls = on;
            })
        }
        .width('100%')

        Row() {
          Text('记住 token（加密存储）')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.rememberToken })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => {
              this.rememberToken = on;
            })
        }
        .width('100%')

        if (this.formError.length > 0) {
          Text('⚠ ' + this.formError)
            .fontSize(13)
            .fontColor(Palette.danger)
            .width('100%')
        }

        Button('连 接')
          .width('100%')
          .height(46)
          .fontSize(16)
          .fontColor(Palette.base)
          .backgroundColor(Palette.accent)
          .borderRadius(10)
          .onClick(() => {
            this.connect();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding(20)
      .backgroundColor(Palette.surface)
      .borderRadius(12)
      .borderWidth(1)
      .borderColor(Palette.border)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Palette.base)
  }
}
