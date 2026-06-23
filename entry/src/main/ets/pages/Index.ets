import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { TerminalController, TerminalSurface } from 'libghostty_ohos';
import { TerminalSession } from '../session/TerminalSession';
import { TerminalRuntime } from '../session/TerminalTab';
import { FishWebSocketDriver } from '../transport/FishWebSocketDriver';
import { DriverState, DriverStatus, FishConnectConfig } from '../transport/TerminalDriver';
import { ConnectionStore, ConnectionProfile, TerminalPrefs, DEFAULT_TERMINAL_PREFS } from '../store/ConnectionStore';
import { Palette } from '../theme/Palette';
import { DEFAULT_FONT_SIZE, clampFontSize } from '../theme/FontScale';
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

// Reactive per-tab metadata that drives the tab strip. The heavy controller /
// session live in TerminalRuntime, keyed by id in `runtimes`.
interface TabMeta {
  id: number;
  title: string;
  state: DriverState;
  statusText: string;
}

@Entry
@Component
struct Index {
  // Each tab owns its own persistent TerminalController + XComponent surface
  // (see terminalsurface-lifecycle memory). Switching tabs only toggles
  // visibility; surfaces stay mounted so terminal state never resets.
  // CRITICAL (focus model): the active terminal XComponent must own keyboard
  // focus — it receives keys/scroll natively only while focused. Every other
  // control is .focusable(false) and hands focus back via focusActiveTerminal().
  private runtimes: Map<number, TerminalRuntime> = new Map<number, TerminalRuntime>();
  private nextId: number = 1;
  private context: common.UIAbilityContext | null = null;
  private store: ConnectionStore | null = null;

  @State private tabs: TabMeta[] = [];
  @State private activeId: number = -1;
  @State private host: string = '192.168.1.10';
  @State private port: string = '8765';
  @State private token: string = '';
  @State private tls: boolean = false;
  @State private rememberToken: boolean = false;
  @State private showToken: boolean = false;
  @State private fontSize: number = DEFAULT_FONT_SIZE;
  @State private formError: string = '';
  @State private focusedField: string = '';
  @State private showSettings: boolean = false;
  @State private settingsInitialTab: number = 0;
  @State private showNewConnection: boolean = false;
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
      this.runtimes.forEach((rt: TerminalRuntime) => {
        rt.session?.onForeground();
      });
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
      return;
    }
    store.loadFontSize(DEFAULT_FONT_SIZE).then((fs: number): void => {
      this.fontSize = clampFontSize(fs);
      this.broadcastConfig();
    });
    store.loadTheme('Aizen_Dark').then((name: string): void => {
      this.themeName = name;
      this.broadcastTheme();
    });
    store.loadTerminalPrefs(DEFAULT_TERMINAL_PREFS).then((prefs: TerminalPrefs): void => {
      this.cursorStyle = prefs.cursorStyle;
      this.cursorBlink = prefs.cursorBlink;
      this.scrollbackLines = prefs.scrollbackLines;
      this.broadcastConfig();
    });
  }

  aboutToDisappear(): void {
    emitter.off(10086);
    this.runtimes.forEach((rt: TerminalRuntime) => {
      rt.session?.stop();
    });
    this.runtimes.clear();
  }

  // ----- settings propagation ------------------------------------------------

  // Apply the current terminal config + theme to one controller (used when a
  // brand-new tab is created so it inherits the active appearance).
  private applySettingsTo(controller: TerminalController): void {
    controller.setTheme(this.themeName);
    controller.updateConfig({
      fontSize: this.fontSize,
      scrollbackLines: this.scrollbackLines,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink
    });
  }

  private broadcastConfig(): void {
    this.runtimes.forEach((rt: TerminalRuntime) => {
      rt.controller.updateConfig({
        fontSize: this.fontSize,
        scrollbackLines: this.scrollbackLines,
        cursorStyle: this.cursorStyle,
        cursorBlink: this.cursorBlink
      });
    });
  }

  private broadcastTheme(): void {
    this.runtimes.forEach((rt: TerminalRuntime) => {
      rt.controller.setTheme(this.themeName);
    });
  }

  // ----- tab lifecycle -------------------------------------------------------

  private activeRuntime(): TerminalRuntime | null {
    const rt: TerminalRuntime | undefined = this.runtimes.get(this.activeId);
    return rt ?? null;
  }

  private activeController(): TerminalController {
    const rt: TerminalRuntime | null = this.activeRuntime();
    return rt ? rt.controller : new TerminalController();
  }

  // Hand keyboard focus back to the active terminal surface.
  private focusActiveTerminal(): void {
    const rt: TerminalRuntime | null = this.activeRuntime();
    if (!rt) {
      return;
    }
    const id: string = rt.surfaceId;
    setTimeout(() => {
      focusControl.requestFocus(id);
    }, 0);
  }

  private updateTabMeta(id: number, state: DriverState, statusText: string): void {
    const next: TabMeta[] = this.tabs.map((t: TabMeta): TabMeta => {
      if (t.id === id) {
        return { id: t.id, title: t.title, state, statusText };
      }
      return t;
    });
    this.tabs = next;
  }

  private updateTabTitle(id: number, title: string): void {
    const trimmed = title.trim();
    if (trimmed.length === 0) return;
    const next: TabMeta[] = this.tabs.map((t: TabMeta): TabMeta => {
      if (t.id === id) {
        return { id: t.id, title: trimmed, state: t.state, statusText: t.statusText };
      }
      return t;
    });
    this.tabs = next;
  }

  // Open a new tab and start a session to the current host/port/token.
  private openTab(): void {
    const host: string = this.host.trim();
    const token: string = this.token.trim();
    const port: number = Number(this.port);
    if (host.length === 0 || !Number.isInteger(port) || port <= 0 || port > 65535 || token.length === 0) {
      // Missing creds — fall back to the connect form by clearing all tabs.
      this.formError = '请先填写连接信息';
      return;
    }

    const id: number = this.nextId++;
    const rt: TerminalRuntime = new TerminalRuntime(id);
    this.applySettingsTo(rt.controller);
    this.runtimes.set(id, rt);

    const meta: TabMeta = { id, title: '终端 ' + id, state: DriverState.Connecting, statusText: '连接中…' };
    this.tabs = this.tabs.concat(meta);
    this.activeId = id;

    const cfg: FishConnectConfig = { host, port, token, tls: this.tls };
    const session: TerminalSession = new TerminalSession(rt.controller, new FishWebSocketDriver(cfg));
    session.onStatus((s: DriverStatus): void => {
      this.updateTabMeta(id, s.state, stateLabel(s));
    });
    session.onTitleChange((title: string): void => {
      this.updateTabTitle(id, title);
    });
    rt.session = session;
    session.start();
    this.focusActiveTerminal();
  }

  private switchTab(id: number): void {
    if (id === this.activeId) {
      this.focusActiveTerminal();
      return;
    }
    this.activeId = id;
    this.focusActiveTerminal();
  }

  private closeTab(id: number): void {
    const rt: TerminalRuntime | undefined = this.runtimes.get(id);
    if (!rt) {
      return; // already closing / closed (guards double-tap on ✕)
    }
    // Stop the driver immediately so no more output/input flows.
    rt.session?.stop();

    const remaining: TabMeta[] = this.tabs.filter((t: TabMeta) => t.id !== id);

    // If we're closing the active tab, move focus to a neighbour FIRST so the
    // surface being destroyed no longer holds keyboard focus / IME — tearing
    // down the focused surface in the same frame could otherwise stall.
    if (this.activeId === id && remaining.length > 0) {
      this.activeId = remaining[remaining.length - 1].id;
      this.focusActiveTerminal();
    }

    // Defer the actual removal (surface unmount + native teardown) to the next
    // tick so the focus/visibility change commits before the XComponent is
    // destroyed.
    setTimeout(() => {
      this.runtimes.delete(id);
      this.tabs = this.tabs.filter((t: TabMeta) => t.id !== id);
      if (this.activeId === id) {
        this.activeId = this.tabs.length > 0 ? this.tabs[this.tabs.length - 1].id : -1;
      }
    }, 0);
  }

  // ----- connect form --------------------------------------------------------

  // "连接管理": show the connect form as an overlay so the user can open a new
  // connection (to the same or a different host) as a fresh tab.
  private openNewConnection(): void {
    this.formError = '';
    this.showNewConnection = true;
  }

  private connectFromForm(): void {
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
    this.showNewConnection = false;
    this.openTab();
  }

  private applyFontSize(size: number): void {
    this.fontSize = size;
    this.broadcastConfig();
    if (this.store) {
      this.store.saveFontSize(size);
    }
  }


  private dotColor(state: DriverState): string {
    switch (state) {
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
        if (this.tabs.length > 0) {
          this.buildTabStrip();
          Stack() {
            ForEach(this.tabs, (tab: TabMeta) => {
              this.buildSurface(tab.id);
            }, (tab: TabMeta) => tab.id.toString())
          }
          .layoutWeight(1)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.showSettings, this.buildSettingsSheet(), {
        preferType: SheetType.CENTER,
        width: '50%',
        height: 600,
        dragBar: false,
        showClose: false,
        backgroundColor: Palette.base,
        onDisappear: () => { this.focusActiveTerminal(); }
      })

      if (this.tabs.length === 0 || this.showNewConnection) {
        this.buildForm();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
  }

  @Builder
  private buildSurface(id: number) {
    // Each surface stays mounted; only the active one is visible & focusable.
    TerminalSurface({
      controller: this.runtimes.get(id)?.controller ?? new TerminalController(),
      surfaceId: this.runtimes.get(id)?.surfaceId ?? ('fishTermSurface_' + id),
      surfaceColor: Palette.base,
      onOpenSettings: () => { this.settingsInitialTab = 0; this.showSettings = true; },
      onOpenShortcuts: () => { this.settingsInitialTab = 2; this.showSettings = true; },
      onOpenConnections: () => { this.openNewConnection(); }
    })
      .width('100%')
      .height('100%')
      .visibility(id === this.activeId ? Visibility.Visible : Visibility.Hidden)
  }

  // Top strip that replaces the system title bar: app logo + tabs + "+" + settings.
  // The right padding reserves room for the system window control buttons that
  // float at the top-right after the decoration bar is hidden, so our settings
  // button sits just to their left without overlapping.
  @Builder
  private buildTabStrip() {
    Row() {
      Image($r('app.media.app_logo'))
        .width(22)
        .height(22)
        .borderRadius(5)
        .margin({ left: 14, right: 10 })

      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.tabs, (tab: TabMeta) => {
            this.buildTabChip(tab)
          }, (tab: TabMeta) => 'chip_' + tab.id.toString())

          // "+" new tab
          Row() {
            Text('+')
              .fontSize(18)
              .fontColor(Palette.textDim)
          }
          .width(28)
          .height(28)
          .justifyContent(FlexAlign.Center)
          .borderRadius(7)
          .focusable(false)
          .onClick(() => { this.openTab(); })
        }
        .height(40)
        .padding({ right: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)

      // settings button (sits to the left of the system window controls)
      Row() {
        this.settingsIcon()
      }
      .width(34)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .borderRadius(7)
      .backgroundColor('#0D1520')
      .focusable(false)
      .onClick(() => { this.showSettings = true; })
    }
    .width('100%')
    .height(40)
    .padding({ right: 130 })
    .backgroundColor('#0A0E13')
  }

  @Builder
  private buildTabChip(tab: TabMeta) {
    Row({ space: 7 }) {
      Text('●')
        .fontSize(8)
        .fontColor(this.dotColor(tab.state))
      Text(tab.title)
        .fontSize(12)
        .fontColor(tab.id === this.activeId ? Palette.text : Palette.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('✕')
        .fontSize(11)
        .fontColor(Palette.textDim)
        .focusable(false)
        .onClick(() => { this.closeTab(tab.id); })
    }
    // Active tab is flush with the terminal below (same bg, no bottom border).
    // Inactive tabs float as small rounded chips.
    .height(tab.id === this.activeId ? 40 : 30)
    .padding({ left: 12, right: 10 })
    .borderRadius(tab.id === this.activeId
      ? { topLeft: 8, topRight: 8, bottomLeft: 0, bottomRight: 0 } as BorderRadiuses
      : { topLeft: 7, topRight: 7, bottomLeft: 7, bottomRight: 7 } as BorderRadiuses)
    .backgroundColor(tab.id === this.activeId ? Palette.base : Color.Transparent)
    .border(tab.id === this.activeId
      ? { width: { top: 1, left: 1, right: 1 }, color: Palette.border }
      : { width: 1, color: Color.Transparent })
    .alignItems(VerticalAlign.Center)
    .focusable(false)
    .onClick(() => { this.switchTab(tab.id); })
  }

  private activeMeta(): TabMeta {
    for (let i: number = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.activeId) {
        return this.tabs[i];
      }
    }
    return { id: -1, title: '', state: DriverState.Idle, statusText: '空闲' };
  }

  // Minimalist "adjustments" icon: two slider tracks with cyan knobs.
  @Builder
  private settingsIcon() {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.Start }) {
        Row().width(16).height(2).borderRadius(1).backgroundColor(Palette.textDim)
        Row()
          .width(6).height(6).borderRadius(3)
          .backgroundColor(Palette.accent)
          .margin({ left: 8 })
      }
      .width(16).height(6)

      Stack({ alignContent: Alignment.Start }) {
        Row().width(16).height(2).borderRadius(1).backgroundColor(Palette.textDim)
        Row()
          .width(6).height(6).borderRadius(3)
          .backgroundColor(Palette.accent)
          .margin({ left: 2 })
      }
      .width(16).height(6)
    }
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private buildSettingsSheet() {
    SettingsPanel({
      controller: this.activeController(),
      store: this.store,
      fontSize: this.fontSize,
      initialTab: this.settingsInitialTab,
      statusText: this.activeMeta().statusText,
      statusColor: this.dotColor(this.activeMeta().state),
      hostLabel: this.host + ':' + this.port,
      themeName: this.themeName,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink,
      scrollbackLines: this.scrollbackLines,
      onThemeChange: (n: string) => { this.themeName = n; this.broadcastTheme(); },
      onCursorStyleChange: (v: number) => { this.cursorStyle = v; this.broadcastConfig(); },
      onCursorBlinkChange: (v: boolean) => { this.cursorBlink = v; this.broadcastConfig(); },
      onScrollbackChange: (v: number) => { this.scrollbackLines = v; this.broadcastConfig(); },
      onFontSizeChange: (s: number) => { this.applyFontSize(s); },
      onClose: () => { this.showSettings = false; }
    })
  }

  @Builder
  private buildForm() {
    Column() {
      // cancel affordance when opened as a "new connection" overlay
      if (this.showNewConnection) {
        Row() {
          Text('✕ 取消')
            .fontSize(14)
            .fontColor(Palette.textDim)
            .focusable(false)
            .onClick(() => { this.showNewConnection = false; this.focusActiveTerminal(); })
        }
        .width('100%')
        .constraintSize({ maxWidth: 420 })
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 10 })
      }

      Column({ space: 10 }) {
        Image($r('app.media.app_logo'))
          .width(72)
          .height(72)
          .borderRadius(16)
        Text(this.showNewConnection ? '新建连接' : 'fish-term')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
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
            .onFocus(() => { this.focusedField = 'host'; })
            .onBlur(() => { if (this.focusedField === 'host') { this.focusedField = ''; } })
            .onChange((v: string) => { this.host = v; })
            .onSubmit(() => { this.connectFromForm(); })
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
            .onFocus(() => { this.focusedField = 'port'; })
            .onBlur(() => { if (this.focusedField === 'port') { this.focusedField = ''; } })
            .onChange((v: string) => { this.port = v; })
            .onSubmit(() => { this.connectFromForm(); })
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
            .onFocus(() => { this.focusedField = 'token'; })
            .onBlur(() => { if (this.focusedField === 'token') { this.focusedField = ''; } })
            .onChange((v: string) => { this.token = v; })
            .onSubmit(() => { this.connectFromForm(); })
          Button(this.showToken ? '隐藏' : '显示')
            .height(44)
            .width(56)
            .fontSize(13)
            .backgroundColor(Palette.inputBg)
            .fontColor(Palette.textDim)
            .borderRadius(8)
            .onClick(() => { this.showToken = !this.showToken; })
        }
        .width('100%')

        Row() {
          Text('TLS (wss)')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.tls })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => { this.tls = on; })
        }
        .width('100%')

        Row() {
          Text('记住 token（加密存储）')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.rememberToken })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => { this.rememberToken = on; })
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
          .onClick(() => { this.connectFromForm(); })
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
