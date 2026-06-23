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
  @State private hoverAddTab: boolean = false;
  @State private hoverSettings: boolean = false;
  @State private hoverLogo: boolean = false;
  @State private hoverCloseId: number = -1;
  @State private hoverTabId: number = -1;
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
  // Real bg/fg colors of the current theme, refreshed after native bind.
  // Used to match the active tab chip and content card precisely so they
  // fuse visually — even when the user picks a light theme.
  @State private themeBg: string = Palette.base;
  @State private themeFg: string = Palette.text;
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
    this.refreshThemeBg();
  }

  // Pull the real background color of the current theme so the tab strip /
  // active tab can match the terminal exactly. Needs a bound native controller;
  // falls back to the previous value when none is available yet.
  private refreshThemeBg(): void {
    this.runtimes.forEach((rt: TerminalRuntime) => {
      const colors: string[] = rt.controller.getThemeColors(this.themeName);
      if (colors && colors.length >= 2 && colors[0].length > 0) {
        this.themeBg = colors[0];
        this.themeFg = colors[1];
      }
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
    // Native bind happens in the surface's onLoad; poll briefly so the tab/
    // content background can pick up the real theme bg once it's available.
    setTimeout(() => { this.refreshThemeBg(); }, 250);
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
          // Terminal content as a rounded card. The frame (Palette.surface,
          // same color as the strip) shows on left/right/bottom because the
          // parent Column pads those sides. Cross-axis stretch fills the rest,
          // so no width('100%') is set (that would overflow the padding and
          // clip the right border).
          Stack() {
            ForEach(this.tabs, (tab: TabMeta) => {
              this.buildSurface(tab.id);
            }, (tab: TabMeta) => tab.id.toString())
          }
          .layoutWeight(1)
          .backgroundColor(this.themeBg)
          .borderRadius({ topLeft: 10, topRight: 10, bottomLeft: 10, bottomRight: 10 })
          .clip(true)
        }
      }
      .width('100%')
      .height('100%')
      // Frame: Palette.surface border on left / right / bottom. The top frame
      // above the tabs is produced inside the (full-height) strip by making
      // the tab chips shorter than the strip — so the strip stays aligned with
      // the system window controls.
      .padding({ left: 8, right: 8, bottom: 8 })
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
    // Frame color matches the strip — forms a consistent border on
    // left / right / bottom of the terminal card.
    .backgroundColor(Palette.surface)
  }

  @Builder
  private buildSurface(id: number) {
    // Each surface stays mounted; only the active one is visible & focusable.
    TerminalSurface({
      controller: this.runtimes.get(id)?.controller ?? new TerminalController(),
      surfaceId: this.runtimes.get(id)?.surfaceId ?? ('fishTermSurface_' + id),
      surfaceColor: this.themeBg,
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
      // Logo: hover dims slightly; click → About page in settings
      Image($r('app.media.app_logo'))
        .width(26)
        .height(26)
        .margin({ left: 14, right: 10 })
        .opacity(this.hoverLogo ? 0.65 : 1.0)
        .scale(this.hoverLogo ? { x: 0.92, y: 0.92 } : { x: 1.0, y: 1.0 })
        .animation({ duration: 150, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverLogo = h; })
        .onClick(() => { this.settingsInitialTab = 3; this.showSettings = true; })

      Scroll() {
        Row({ space: 4 }) {
          ForEach(this.tabs, (tab: TabMeta) => {
            this.buildTabChip(tab)
          }, (tab: TabMeta) => 'chip_' + tab.id.toString())

          // "+" new tab — vertically centered in the strip
          Row() {
            Text('+')
              .fontSize(16)
              .fontColor(this.hoverAddTab ? Palette.textDim : '#606878')
              .animation({ duration: 120, curve: Curve.EaseOut })
          }
          .width(24)
          .height(24)
          .justifyContent(FlexAlign.Center)
          .borderRadius(5)
          .backgroundColor(this.hoverAddTab ? '#FFFFFF0C' : Color.Transparent)
          .animation({ duration: 120, curve: Curve.EaseOut })
          .focusable(false)
          .onHover((h: boolean) => { this.hoverAddTab = h; })
          .onClick(() => { this.openTab(); })
        }
        .height(40)
        .padding({ right: 8 })
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)

      // Settings button — borderless, same visual weight as system controls
      Row() {
        this.settingsIcon()
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.hoverSettings ? '#FFFFFF0C' : Color.Transparent)
      .animation({ duration: 150, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverSettings = h; })
      .onClick(() => { this.settingsInitialTab = 0; this.showSettings = true; })
    }
    .width('100%')
    .height(40)
    .padding({ right: 130 })
    .backgroundColor(Palette.surface)
  }

  @Builder
  private buildTabChip(tab: TabMeta) {
    Row({ space: 7 }) {
      Text('●')
        .fontSize(8)
        .fontColor(this.dotColor(tab.state))
      Text(tab.title)
        .fontSize(12)
        .fontColor(tab.id === this.activeId ? this.themeFg : Palette.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // ✕ turns red on hover to signal "this will close"
      Text('✕')
        .fontSize(11)
        .fontColor(this.hoverCloseId === tab.id ? Palette.danger
          : (tab.id === this.activeId ? this.themeFg : Palette.textDim))
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverCloseId = h ? tab.id : -1; })
        .onClick(() => { this.closeTab(tab.id); })
    }
    .height(tab.id === this.activeId ? 30 : 24)
    .padding({ left: 12, right: 10 })
    .borderRadius(tab.id === this.activeId
      ? { topLeft: 9, topRight: 9, bottomLeft: 0, bottomRight: 0 } as BorderRadiuses
      : { topLeft: 7, topRight: 7, bottomLeft: 7, bottomRight: 7 } as BorderRadiuses)
    // Inactive tab gets a subtle highlight on hover
    .backgroundColor(tab.id === this.activeId ? this.themeBg
      : (this.hoverTabId === tab.id ? '#FFFFFF0A' : Color.Transparent))
    .animation({ duration: 150, curve: Curve.EaseOut })
    .alignItems(VerticalAlign.Center)
    .focusable(false)
    .onHover((h: boolean) => { this.hoverTabId = h ? tab.id : -1; })
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

  // Thin-line "sliders" icon, monochrome to match the system window-control
  // buttons (minimize / maximize / close) it sits beside: same light-gray
  // stroke weight, hollow knobs, no fill, no accent color.
  @Builder
  private settingsIcon() {
    Column({ space: 5 }) {
      // top slider: knob on the right
      Stack({ alignContent: Alignment.Start }) {
        Row().width(14).height(1).borderRadius(0.5).backgroundColor('#B8BEC9')
        Circle({ width: 4.5, height: 4.5 })
          .fill(Palette.surface)
          .stroke('#B8BEC9')
          .strokeWidth(1)
          .margin({ left: 7 })
      }
      .width(14).height(4.5)

      // bottom slider: knob on the left
      Stack({ alignContent: Alignment.Start }) {
        Row().width(14).height(1).borderRadius(0.5).backgroundColor('#B8BEC9')
        Circle({ width: 4.5, height: 4.5 })
          .fill(Palette.surface)
          .stroke('#B8BEC9')
          .strokeWidth(1)
          .margin({ left: 2.5 })
      }
      .width(14).height(4.5)
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
