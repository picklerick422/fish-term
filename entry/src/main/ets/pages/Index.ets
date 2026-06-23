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
  // Bumped on Ctrl+Shift+F to open the find overlay on the active terminal.
  @State private searchSignal: number = 0;
  // First-run onboarding guide.
  @State private showGuide: boolean = false;
  @State private guideStep: number = 0;
  // Hover states for guide button and guide card buttons
  @State private hoverGuide: boolean = false;
  @State private guideHover: string = '';
  // Guide page slide direction (true = sliding forward / to next step).
  @State private guideForward: boolean = true;
  // Tab drag-reorder via horizontal PanGesture (live reorder, stays on baseline).
  @State private dragTabId: number = -1;
  @State private dragOffsetX: number = 0;
  @State private dragSwaps: number = 0;
  private dragUnit: number = 110;
  private didDrag: boolean = false;
  private lastDragEnd: number = 0;
  private chipWidths: Map<number, number> = new Map<number, number>();

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
    store.loadOnboarded().then((done: boolean): void => {
      if (!done) {
        this.showGuide = true;
        this.guideStep = 0;
      }
    });
  }

  private finishGuide(): void {
    this.showGuide = false;
    this.guideStep = 0;
    if (this.store) {
      this.store.saveOnboarded(true);
    }
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

  // Ctrl+1..9 — jump to the Nth tab (1-based). Out-of-range is ignored.
  private switchToIndex(index: number): void {
    if (index >= 0 && index < this.tabs.length) {
      this.switchTab(this.tabs[index].id);
    }
  }

  // Ctrl+Tab — cycle to the next (dir=1) / previous (dir=-1) tab, wrapping.
  private cycleTab(dir: number): void {
    if (this.tabs.length <= 1) {
      return;
    }
    let cur: number = 0;
    for (let i: number = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.activeId) {
        cur = i;
        break;
      }
    }
    const n: number = this.tabs.length;
    const next: number = ((cur + dir) % n + n) % n;
    this.switchTab(this.tabs[next].id);
  }

  // Ctrl+Shift+F — open the find overlay on the active terminal.
  private requestSearch(): void {
    if (this.tabs.length > 0) {
      this.searchSignal = this.searchSignal + 1;
    }
  }

  // Average measured chip width (vp) — used to decide when the dragged chip has
  // crossed a neighbour during a live reorder. Falls back to 110 before measure.
  private avgChipWidth(): number {
    if (this.chipWidths.size === 0) {
      return 110;
    }
    let sum: number = 0;
    this.chipWidths.forEach((w: number) => { sum += w; });
    return Math.max(48, sum / this.chipWidths.size);
  }

  // Move the dragged chip one slot in `dir` (±1). Returns false at the edges.
  private moveDragged(dir: number): boolean {
    let idx: number = -1;
    for (let i: number = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.dragTabId) {
        idx = i;
        break;
      }
    }
    const target: number = idx + dir;
    if (idx < 0 || target < 0 || target >= this.tabs.length) {
      return false;
    }
    const list: TabMeta[] = this.tabs.slice();
    const moved: TabMeta = list.splice(idx, 1)[0];
    list.splice(target, 0, moved);
    this.tabs = list;
    return true;
  }

  // Called continuously during a horizontal pan: as the dragged chip's residual
  // offset crosses ~0.6 of a chip width, swap it past the neighbour so the other
  // tabs re-flow live (with animation) under the finger.
  private onDragUpdate(offsetX: number): void {
    this.dragOffsetX = offsetX;
    if (Math.abs(offsetX) > 4) {
      this.didDrag = true;
    }
    let guard: number = 0;
    while (guard < 20) {
      guard = guard + 1;
      const residual: number = this.dragOffsetX - this.dragSwaps * this.dragUnit;
      if (residual > this.dragUnit * 0.6) {
        if (this.moveDragged(1)) {
          this.dragSwaps = this.dragSwaps + 1;
        } else {
          break;
        }
      } else if (residual < -this.dragUnit * 0.6) {
        if (this.moveDragged(-1)) {
          this.dragSwaps = this.dragSwaps - 1;
        } else {
          break;
        }
      } else {
        break;
      }
    }
  }

  // Force an immediate reconnect of the active tab's session.
  private reconnectActive(): void {
    const rt: TerminalRuntime | null = this.activeRuntime();
    if (rt) {
      rt.session?.reconnectNow();
    }
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
          Stack({ alignContent: Alignment.Top }) {
            ForEach(this.tabs, (tab: TabMeta) => {
              this.buildSurface(tab.id);
            }, (tab: TabMeta) => tab.id.toString())
            this.buildStatusBanner()
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

      if (this.showGuide) {
        this.buildGuide();
      }
    }
    .width('100%')
    .height('100%')
    // Frame color matches the strip — forms a consistent border on
    // left / right / bottom of the terminal card.
    .backgroundColor(Palette.surface)
    // App-level keyboard shortcuts (work while the window is focused, even
    // though the terminal XComponent owns native key focus).
    .keyboardShortcut('f', [ModifierKey.CTRL], () => { this.requestSearch(); })
    .keyboardShortcut('f', [ModifierKey.CTRL, ModifierKey.SHIFT], () => { this.requestSearch(); })
    .keyboardShortcut('t', [ModifierKey.CTRL], () => { this.openTab(); })
    .keyboardShortcut('w', [ModifierKey.CTRL], () => { this.closeTab(this.activeId); })
    .keyboardShortcut(FunctionKey.TAB, [ModifierKey.CTRL], () => { this.cycleTab(1); })
    .keyboardShortcut('1', [ModifierKey.CTRL], () => { this.switchToIndex(0); })
    .keyboardShortcut('2', [ModifierKey.CTRL], () => { this.switchToIndex(1); })
    .keyboardShortcut('3', [ModifierKey.CTRL], () => { this.switchToIndex(2); })
    .keyboardShortcut('4', [ModifierKey.CTRL], () => { this.switchToIndex(3); })
    .keyboardShortcut('5', [ModifierKey.CTRL], () => { this.switchToIndex(4); })
    .keyboardShortcut('6', [ModifierKey.CTRL], () => { this.switchToIndex(5); })
    .keyboardShortcut('7', [ModifierKey.CTRL], () => { this.switchToIndex(6); })
    .keyboardShortcut('8', [ModifierKey.CTRL], () => { this.switchToIndex(7); })
    .keyboardShortcut('9', [ModifierKey.CTRL], () => { this.switchToIndex(8); })
  }

  @Builder
  private buildSurface(id: number) {
    // Each surface stays mounted; only the active one is visible & focusable.
    TerminalSurface({
      controller: this.runtimes.get(id)?.controller ?? new TerminalController(),
      surfaceId: this.runtimes.get(id)?.surfaceId ?? ('fishTermSurface_' + id),
      surfaceColor: this.themeBg,
      isActiveTab: id === this.activeId,
      searchSignal: this.searchSignal,
      onOpenSettings: () => { this.settingsInitialTab = 0; this.showSettings = true; },
      onOpenShortcuts: () => { this.settingsInitialTab = 2; this.showSettings = true; },
      onOpenConnections: () => { this.openNewConnection(); }
    })
      .width('100%')
      .height('100%')
      .visibility(id === this.activeId ? Visibility.Visible : Visibility.Hidden)
  }

  // Thin banner over the terminal shown while the active tab is not connected.
  // Gives the user live feedback plus a one-tap "立即重连".
  @Builder
  private buildStatusBanner() {
    if (this.activeMeta().state === DriverState.Reconnecting
      || this.activeMeta().state === DriverState.Error
      || this.activeMeta().state === DriverState.Connecting) {
      Row({ space: 8 }) {
        Text('●')
          .fontSize(9)
          .fontColor(this.dotColor(this.activeMeta().state))
        Text(this.activeMeta().statusText)
          .fontSize(12)
          .fontColor(Palette.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.activeMeta().state !== DriverState.Connecting) {
          Text('立即重连')
            .fontSize(12)
            .fontColor(Palette.accent)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(6)
            .backgroundColor('#1FFFFFFF')
            .focusable(false)
            .onClick(() => { this.reconnectActive(); })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#E6171C25')
      .alignItems(VerticalAlign.Center)
    }
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
        // nudged down so it sits closer to the tab baseline (strip height unchanged)
        .margin({ left: 14, right: 10, top: 7 })
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
          .margin({ bottom: 5 })
          .justifyContent(FlexAlign.Center)
          .borderRadius(5)
          .backgroundColor(this.hoverAddTab ? '#1FFFFFFF' : Color.Transparent)
          .animation({ duration: 120, curve: Curve.EaseOut })
          .focusable(false)
          .onHover((h: boolean) => { this.hoverAddTab = h; })
          .onClick(() => { this.openTab(); })
        }
        .height(40)
        .padding({ right: 8 })
        // Bottom-align so the active tab's flat bottom edge sits flush on the
        // terminal card below it — that's what makes them visually fuse.
        .alignItems(VerticalAlign.Bottom)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)

      // Guide help button — line-art circled "?" matching the system controls
      Row() {
        Row() {
          this.helpIcon()
        }
        .width(30)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .borderRadius(7)
        .backgroundColor(this.hoverGuide ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 150, curve: Curve.EaseOut })
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .focusable(false)
      .onHover((h: boolean) => { this.hoverGuide = h; })
      .onClick(() => { this.guideStep = 0; this.guideForward = true; this.showGuide = true; })

      // Settings button — borderless, same visual weight as system controls.
      // Hover highlight lives on a smaller inner box (not the full 40×40 hit
      // area) so it matches the size of the system window-control buttons.
      Row() {
        Row() {
          this.settingsIcon()
        }
        .width(30)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .borderRadius(7)
        .backgroundColor(this.hoverSettings ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 150, curve: Curve.EaseOut })
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
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
      : (this.hoverTabId === tab.id ? '#1FFFFFFF' : Color.Transparent))
    // The dragged chip follows the finger via a residual X translate; the other
    // chips re-flow live (with animation) as the array is spliced mid-drag. The
    // chip never leaves the tab baseline (y is always 0).
    .translate({ x: this.dragTabId === tab.id ? (this.dragOffsetX - this.dragSwaps * this.dragUnit) : 0, y: 0 })
    .zIndex(this.dragTabId === tab.id ? 10 : 0)
    .scale(this.dragTabId === tab.id ? { x: 1.04, y: 1.04 } : { x: 1.0, y: 1.0 })
    .shadow(this.dragTabId === tab.id
      ? { radius: 12, color: '#66000000', offsetX: 0, offsetY: 2 }
      : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
    .animation(this.dragTabId === tab.id
      ? { duration: 0 }          // dragged chip tracks the finger with no lag
      : { duration: 180, curve: Curve.Friction })
    .alignItems(VerticalAlign.Center)
    .focusable(false)
    // Measure width so live-reorder thresholds match the real chip sizes.
    .onAreaChange((_o: Area, n: Area) => { this.chipWidths.set(tab.id, Number(n.width)); })
    .onHover((h: boolean) => { this.hoverTabId = h ? tab.id : -1; })
    .onClick(() => {
      // Ignore the click that fires right after a real drag; later taps work.
      if (Date.now() - this.lastDragEnd > 250) {
        this.switchTab(tab.id);
      }
    })
    // Whole-chip horizontal PanGesture for drag-to-reorder. priorityGesture
    // wins over the parent Scroll's horizontal scroll.
    .priorityGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 5 })
        .onActionStart(() => {
          this.dragTabId = tab.id;
          this.dragOffsetX = 0;
          this.dragSwaps = 0;
          this.didDrag = false;
          this.dragUnit = this.avgChipWidth();
        })
        .onActionUpdate((e: GestureEvent) => {
          this.onDragUpdate(e.offsetX);
        })
        .onActionEnd(() => {
          if (this.didDrag) {
            this.lastDragEnd = Date.now();
          }
          this.dragTabId = -1;
          this.dragOffsetX = 0;
          this.dragSwaps = 0;
        })
        .onActionCancel(() => {
          if (this.didDrag) {
            this.lastDragEnd = Date.now();
          }
          this.dragTabId = -1;
          this.dragOffsetX = 0;
          this.dragSwaps = 0;
        })
    )
  }

  private activeMeta(): TabMeta {
    for (let i: number = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.activeId) {
        return this.tabs[i];
      }
    }
    return { id: -1, title: '', state: DriverState.Idle, statusText: '空闲' };
  }

  // Line-art help icon (hollow circle + "?") — same #B8BEC9 thin stroke as the
  // settings icon and the system caption buttons it sits beside.
  @Builder
  private helpIcon() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: 15, height: 15 })
        .fill(Color.Transparent)
        .stroke(this.hoverGuide ? '#F4F7FB' : '#B8BEC9')
        .strokeWidth(1)
      Text('?')
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.hoverGuide ? '#F4F7FB' : '#B8BEC9')
    }
    .width(15)
    .height(15)
    .animation({ duration: 120, curve: Curve.EaseOut })
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
      onReplayGuide: () => { this.showSettings = false; this.guideStep = 0; this.showGuide = true; },
      onClose: () => { this.showSettings = false; }
    })
  }

  // ----- onboarding guide ----------------------------------------------------

  private readonly guideCount: number = 5;

  private guideTitle(step: number): string {
    switch (step) {
      case 0: return '欢迎使用 fish-term';
      case 1: return '第 1 步 · 运行 fish-agent';
      case 2: return '第 2 步 · 获取连接信息';
      case 3: return '第 3 步 · 新建连接';
      default: return '第 4 步 · 开始使用';
    }
  }

  private guideDesc(step: number): string {
    switch (step) {
      case 0:
        return 'fish-term 是一个连接到 fish-agent 的 HarmonyOS 终端。\n只需几步就能在手机/平板上获得完整的远程终端体验。';
      case 1:
        return '在你的电脑或服务器上下载并运行 fish-agent：\n\n  ./fish-agent --listen 0.0.0.0:8765\n\n它会启动一个 WebSocket 服务，等待终端接入。';
      case 2:
        return '启动后 fish-agent 会输出三项信息：\n\n  · 主机地址 host（如 192.168.1.10）\n  · 端口 port（默认 8765）\n  · 访问 token（用于鉴权）\n\n确保设备与该主机在同一网络可达。';
      case 3:
        return '回到 fish-term，在首页填入 host / 端口 / token，\n如需加密传输可打开 TLS(wss)，点击「连接」即可开启第一个终端标签页。';
      default:
        return '常用操作：\n\n  · 右键终端：复制 / 粘贴 / 查找 / 缓冲区\n  · Ctrl+F：查找；Ctrl+Shift+C/V：复制/粘贴\n  · Ctrl+T 新建标签，Ctrl+W 关闭，Ctrl+1~9 / Ctrl+Tab 切换\n  · 标签可拖拽排序；设置里可换主题、字号、光标样式';
    }
  }

  // Placeholder filename for the screenshot to drop in for each step.
  private guideImageName(step: number): string {
    return 'guide_' + step + '.png';
  }

  // Navigate the guide; sets the slide direction so the page animates in/out
  // horizontally. Past the last step it finishes onboarding.
  private goStep(dir: number): void {
    const target: number = this.guideStep + dir;
    if (target >= this.guideCount) {
      this.finishGuide();
      return;
    }
    if (target < 0) {
      return;
    }
    this.guideForward = dir > 0;
    this.guideStep = target;
  }

  // Horizontal slide+fade used by the guide pages and settings sub-pages.
  private slideEffect(forward: boolean): TransitionEffect {
    const dx: number = forward ? 48 : -48;
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: dx }).combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.EaseOut }),
      TransitionEffect.translate({ x: -dx }).combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.EaseOut })
    );
  }

  // One guide page (image + title + description), wrapped so it can slide.
  @Builder
  private guideBody(step: number) {
    Column() {
      // Image placeholder — replace with real screenshots later.
      Stack({ alignContent: Alignment.Center }) {
        Column({ space: 6 }) {
          Text('🖼')
            .fontSize(34)
            .fontColor(Palette.textDim)
          Text('图片占位 · ' + this.guideImageName(step))
            .fontSize(12)
            .fontColor(Palette.textDim)
        }
      }
      .width('100%')
      .height(180)
      .backgroundColor(Palette.inputBg)
      .borderRadius(12)
      .border({ width: 1, color: Palette.border })
      .margin({ bottom: 18 })

      Text(this.guideTitle(step))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.text)
        .width('100%')
        .margin({ bottom: 10 })

      Text(this.guideDesc(step))
        .fontSize(14)
        .fontColor(Palette.textDim)
        .lineHeight(22)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .transition(this.slideEffect(this.guideForward))
  }

  @Builder
  private buildGuide() {
    Column() {
      Column() {
        // Sliding page area: ForEach keyed by step so the old page exits and the
        // new one enters with the horizontal slide transition.
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach([this.guideStep], (s: number) => {
            this.guideBody(s)
          }, (s: number) => 'guide_' + s.toString())
        }
        .width('100%')
        .constraintSize({ minHeight: 320 })
        .clip(true)

        // Step dots
        Row({ space: 6 }) {
          ForEach(['0', '1', '2', '3', '4'], (s: string) => {
            Circle({ width: 7, height: 7 })
              .fill(Number(s) === this.guideStep ? Palette.accent : Palette.border)
          }, (s: string) => s)
        }
        .margin({ top: 20, bottom: 18 })
        .justifyContent(FlexAlign.Center)

        Row({ space: 10 }) {
          Text('跳过')
            .fontSize(14)
            .fontColor(this.guideHover === 'skip' ? Palette.text : Palette.textDim)
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(8)
            .backgroundColor(this.guideHover === 'skip' ? '#1FFFFFFF' : Color.Transparent)
            .animation({ duration: 120, curve: Curve.EaseOut })
            .focusable(false)
            .onHover((h: boolean) => { this.guideHover = h ? 'skip' : ''; })
            .onClick(() => { this.finishGuide(); })

          Blank()

          if (this.guideStep > 0) {
            Text('上一步')
              .fontSize(14)
              .fontColor(Palette.text)
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .borderRadius(9)
              .backgroundColor(this.guideHover === 'prev' ? '#1FFFFFFF' : Palette.surface)
              .border({ width: 1, color: Palette.border })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .focusable(false)
              .onHover((h: boolean) => { this.guideHover = h ? 'prev' : ''; })
              .onClick(() => { this.goStep(-1); })
          }

          Text(this.guideStep >= this.guideCount - 1 ? '开始使用' : '下一步')
            .fontSize(14)
            .fontColor(Palette.base)
            .padding({ left: 18, right: 18, top: 9, bottom: 9 })
            .borderRadius(9)
            .opacity(this.guideHover === 'next' ? 0.85 : 1.0)
            .scale(this.guideHover === 'next' ? { x: 0.97, y: 0.97 } : { x: 1.0, y: 1.0 })
            .backgroundColor(Palette.accent)
            .animation({ duration: 120, curve: Curve.EaseOut })
            .focusable(false)
            .onHover((h: boolean) => { this.guideHover = h ? 'next' : ''; })
            .onClick(() => { this.goStep(1); })
        }
        .width('100%')
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .constraintSize({ maxWidth: 460 })
      .padding(24)
      .backgroundColor(Palette.base)
      .borderRadius(16)
      .border({ width: 1, color: Palette.border })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#CC000000')
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
