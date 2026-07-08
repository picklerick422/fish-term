import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { font, curves, window } from '@kit.ArkUI';
import { TerminalController, TerminalSurface } from 'libghostty_ohos';
import { TerminalSession } from '../session/TerminalSession';
import { TerminalRuntime } from '../session/TerminalTab';
import { FishWebSocketDriver } from '../transport/FishWebSocketDriver';
import { DriverState, DriverStatus, FishConnectConfig } from '../transport/TerminalDriver';
import { ConnectionStore, ConnectionProfile, TerminalPrefs, DEFAULT_TERMINAL_PREFS, SavedSession, SavedTab } from '../store/ConnectionStore';
import { Palette } from '../theme/Palette';
import {
  DEFAULT_FONT_SIZE, clampFontSize,
  DEFAULT_LINE_SPACING, clampLineSpacing,
  DEFAULT_UI_FONT, DEFAULT_TERM_FONT,
  DEFAULT_FONT_SCALE_BOOST, DEFAULT_CJK_VERTICAL_OFFSET, DEFAULT_CHARACTER_SPACING,
  clampFontScaleBoost, clampCjkVerticalOffset, clampCharacterSpacing
} from '../theme/FontScale';
import { SettingsPanel } from './SettingsPanel';
import { CrashLogPanel } from './CrashLogPanel';
import { CrashHandler } from '../crash/CrashHandler';
import { CrashType, CrashLogEntry } from '../crash/CrashTypes';
import { CrashStore } from '../crash/CrashStore';

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
// Must be @Observed class — ArkUI V1 tracks nested changes on interface fields
// only when the whole array is reassigned AND ForEach keys differ. @Observed
// makes property changes reliably trigger UI refresh.
@Observed
class TabMeta {
  id: number;
  title: string;
  state: DriverState;
  statusText: string;
  constructor(id: number, title: string, state: DriverState, statusText: string) {
    this.id = id;
    this.title = title;
    this.state = state;
    this.statusText = statusText;
  }
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
  @State private renameTabId: number = -1;
  @State private renameText: string = '';
  @State private showRenameDialog: boolean = false;
  @State private hoverMenuAction: string = '';
  @State private host: string = '192.168.1.10';
  @State private port: string = '8765';
  @State private token: string = '';
  @State private tls: boolean = false;
  @State private rememberToken: boolean = false;
  @State private showToken: boolean = false;
  @State private fontSize: number = DEFAULT_FONT_SIZE;
  @State private lineSpacing: number = DEFAULT_LINE_SPACING;
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
  @State private uiFontFamily: string = DEFAULT_UI_FONT;
  @State private termFontFamily: string = DEFAULT_TERM_FONT;
  @State private fontScaleBoost: number = DEFAULT_FONT_SCALE_BOOST;
  @State private cjkVerticalOffset: number = DEFAULT_CJK_VERTICAL_OFFSET;
  @State private characterSpacing: number = DEFAULT_CHARACTER_SPACING;
  @State private restoreTabsEnabled: boolean = true;
  @State private restoreChecked: boolean = false;
  // Bumped on Ctrl+Shift+F to open the find overlay on the active terminal.
  @State private searchSignal: number = 0;
  // First-run onboarding guide.
  @State private showGuide: boolean = false;
  @State private guideStep: number = 0;
  // Background mask opacity for fade-in/out animation.
  @State private guideBgOpacity: number = 0;
  // Hover states for guide button and guide card buttons
  @State private hoverGuide: boolean = false;
  @State private guideHover: string = '';
  // Drives the native horizontal slide between guide pages.
  private guideTabs: TabsController = new TabsController();
  @State private showCrashLog: boolean = false;
  @State private crashEntry: CrashLogEntry = {
    id: '', timestamp: 0, crashType: CrashType.JS_CRASH,
    summary: '', stackTrace: '', systemLog: '',
    deviceInfo: { deviceModel: '', osVersion: '', appVersion: '' },
    logFileName: '', viewed: false
  };
  // Tab drag-reorder via horizontal PanGesture (live reorder, stays on baseline).
  @State private dragTabId: number = -1;
  @State private dragOffsetX: number = 0;
  @State private dragSwaps: number = 0;
  private dragUnit: number = 110;
  private didDrag: boolean = false;
  private lastDragEnd: number = 0;
  private chipWidths: Map<number, number> = new Map<number, number>();
  private saveDebounceTimer: number = -1;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new ConnectionStore(this.context);

    // Register bundled custom fonts in the active UI context.
    // font.registerFont() was deprecated from API 18 — must use UIContext.getFont().
    try {
      const fontMgr = this.getUIContext().getFont();
      fontMgr.registerFont({
        familyName: 'Inter',
        familySrc: $rawfile('fonts/Inter-Regular.otf')
      });
      fontMgr.registerFont({
        familyName: 'Source Serif 4',
        familySrc: $rawfile('fonts/SourceSerif4-Regular.otf')
      });
      fontMgr.registerFont({
        familyName: 'Claude Sans',
        familySrc: $rawfile('fonts/ClaudeSans-Regular.ttf')
      });
      fontMgr.registerFont({
        familyName: 'Cascadia Code',
        familySrc: $rawfile('fonts/CascadiaCode.ttf')
      });
    } catch (e) {
      // Non-fatal: fontFamily() falls back gracefully.
    }

    this.loadProfile();
    this.loadSettings();
    this.loadRestoreTabsAndRestore();
    emitter.on({ eventId: 10086 }, () => {
      this.runtimes.forEach((rt: TerminalRuntime) => {
        rt.session?.onForeground();
      });
      this.focusActiveTerminal();
    });
    // Window-level focus listener: when the window gains focus (e.g. Alt+Tab back,
    // clicking the title bar after another app), re-route hardware keyboard to the
    // active terminal. Uses 'windowEvent' with WINDOW_ACTIVE — the only focus
    // signal available on API 20. Without this, keystrokes land on the last-focused
    // ArkUI widget (a tab chip, a button) and Ctrl-key events are misrouted.
    window.getLastWindow(this.context).then((appWindow: window.Window) => {
      appWindow.on('windowEvent', (eventType: window.WindowEventType) => {
        if (eventType === window.WindowEventType.WINDOW_ACTIVE) {
          this.focusActiveTerminal();
        }
      });
    }).catch((_err: Object) => {
      // Non-fatal: the emitter event above is the primary path.
    });
    // 检查是否有待展示的崩溃日志（仅在用户未关闭崩溃提醒时显示）
    if (this.store) {
      this.store.loadShowCrashOnStartup().then((show: boolean) => {
        if (show) {
          const pendingCrash = CrashHandler.consumePendingEntry();
          if (pendingCrash) {
            this.crashEntry = pendingCrash;
            this.showCrashLog = true;
          }
        }
      });
    }
  }

  private loadRestoreTabsAndRestore(): void {
    const store: ConnectionStore | null = this.store;
    if (!store) {
      this.restoreChecked = true;
      return;
    }
    store.loadRestoreTabsEnabled().then((enabled: boolean): void => {
      this.restoreTabsEnabled = enabled;
      if (!enabled) {
        this.restoreChecked = true;
        return;
      }
      store.loadSession().then((session: SavedSession | null): void => {
        if (!session || session.tabs.length === 0) {
          this.restoreChecked = true;
          return;
        }
        // Hide connection form — tabs are being restored.
        this.showNewConnection = false;
        for (let i: number = 0; i < session.tabs.length; i++) {
          const t: SavedTab = session.tabs[i];
          this.openTab({
            host: t.host,
            port: t.port,
            token: t.token,
            tls: t.tls,
            cwd: t.cwd,
            shell: t.shell,
            sessionId: t.sessionId
          }, t.title);
        }
        // Restore active tab by saved index.
        if (session.activeIndex >= 0 && session.activeIndex < this.tabs.length) {
          this.activeId = this.tabs[session.activeIndex].id;
          this.focusActiveTerminal();
        }
        this.restoreChecked = true;
        // Re-apply saved titles after a short delay to survive any async
        // callbacks that fire during session startup (status events, etc.).
        setTimeout(() => {
          for (let i: number = 0; i < this.tabs.length && i < session.tabs.length; i++) {
            const savedTitle: string = session.tabs[i].title;
            if (savedTitle.length > 0) {
              this.updateTabTitle(this.tabs[i].id, savedTitle);
            }
          }
        }, 500);
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
    store.loadLineSpacing(DEFAULT_LINE_SPACING).then((ls: number): void => {
      this.lineSpacing = clampLineSpacing(ls);
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
        this.openGuide();
      }
    });
    store.loadFontFamily(DEFAULT_UI_FONT, true).then((f: string): void => {
      this.uiFontFamily = f;
    });
    store.loadFontFamily(DEFAULT_TERM_FONT, false).then((f: string): void => {
      this.termFontFamily = f;
      if (f.length > 0) {
        this.broadcastConfig();
      }
    });
    store.loadFontScaleBoost(DEFAULT_FONT_SCALE_BOOST).then((v: number): void => {
      this.fontScaleBoost = v;
    });
    store.loadCjkVerticalOffset(DEFAULT_CJK_VERTICAL_OFFSET).then((v: number): void => {
      this.cjkVerticalOffset = v;
    });
    store.loadCharacterSpacing(DEFAULT_CHARACTER_SPACING).then((v: number): void => {
      this.characterSpacing = v;
    });
  }

  // Guide appear/disappear animation — replicates the native bindSheet(CENTER)
  // motion: card slides up + fades in, background mask fades in/out.
  private readonly guideAnimCurve = curves.cubicBezierCurve(0.32, 0.72, 0.0, 1.0);

  private openGuide(): void {
    this.showGuide = true;
    this.guideStep = 0;
    animateTo({ duration: 280, curve: this.guideAnimCurve }, () => {
      this.guideBgOpacity = 1;
    });
  }

  // Animate out, then tear down DOM after the transition finishes.
  private closeGuide(then?: () => void): void {
    animateTo({ duration: 250, curve: this.guideAnimCurve }, () => {
      this.showGuide = false;
      this.guideBgOpacity = 0;
    });
    setTimeout(() => {
      this.guideStep = 0;
      if (then) {
        then();
      }
    }, 260);
  }

  private finishGuide(): void {
    this.closeGuide(() => {
      if (this.store) {
        this.store.saveOnboarded(true);
      }
    });
  }

  aboutToDisappear(): void {
    emitter.off(10086);
    this.stopLiveBgPolling();
    // Flush any pending debounced save immediately before tearing down.
    if (this.saveDebounceTimer >= 0) {
      clearTimeout(this.saveDebounceTimer);
      this.saveDebounceTimer = -1;
    }
    this.doSaveSession();
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
      fontFamily: this.termFontFamily,
      lineSpacing: this.lineSpacing,
      scrollbackLines: this.scrollbackLines,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink,
      fontScaleBoost: this.fontScaleBoost,
      cjkVerticalOffset: this.cjkVerticalOffset,
      characterSpacing: this.characterSpacing
    });
  }

  private broadcastConfig(): void {
    this.runtimes.forEach((rt: TerminalRuntime) => {
      rt.controller.updateConfig({
        fontSize: this.fontSize,
        fontFamily: this.termFontFamily,
        lineSpacing: this.lineSpacing,
        scrollbackLines: this.scrollbackLines,
        cursorStyle: this.cursorStyle,
        cursorBlink: this.cursorBlink,
        fontScaleBoost: this.fontScaleBoost,
        cjkVerticalOffset: this.cjkVerticalOffset,
        characterSpacing: this.characterSpacing
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
    const rt: TerminalRuntime | null = this.activeRuntime();
    if (!rt) {
      return;
    }
    const colors: string[] = rt.controller.getThemeColors(this.themeName);
    if (colors && colors.length >= 2 && colors[0].length > 0) {
      this.themeBg = colors[0];
      this.themeFg = colors[1];
    }
  }

  // Poll the active controller's live background color and update the tab
  // strip / terminal card if it changed (e.g. via OSC 11 from opencode).
  private liveBgTimer: number = -1;
  private startLiveBgPolling(): void {
    if (this.liveBgTimer >= 0) {
      return;
    }
    this.liveBgTimer = setInterval(() => {
      this.syncLiveBackground();
    }, 500) as number;
  }
  private stopLiveBgPolling(): void {
    if (this.liveBgTimer >= 0) {
      clearInterval(this.liveBgTimer);
      this.liveBgTimer = -1;
    }
  }
  private syncLiveBackground(): void {
    const rt: TerminalRuntime | null = this.activeRuntime();
    if (!rt || this.showSettings || this.showRenameDialog) {
      return;
    }
    const liveArgb: number = rt.controller.getCurrentBgColor();
    const live: string = Index.argbToHex(liveArgb);
    if (live.length > 0 && live !== this.themeBg) {
      this.themeBg = live;
      this.themeFg = Index.contrastFg(liveArgb);
    }
  }

  // #RRGGBB from ARGB number
  static argbToHex(argb: number): string {
    const r: number = (argb >> 16) & 0xFF;
    const g: number = (argb >> 8) & 0xFF;
    const b: number = argb & 0xFF;
    return '#' + [r, g, b].map((c: number) => c.toString(16).padStart(2, '0').toUpperCase()).join('');
  }

  // Simple luminance heuristic for contrast foreground.
  static contrastFg(argb: number): string {
    const r: number = (argb >> 16) & 0xFF;
    const g: number = (argb >> 8) & 0xFF;
    const b: number = argb & 0xFF;
    // Perceived brightness (sRGB weights)
    const lum: number = 0.299 * r + 0.587 * g + 0.114 * b;
    return lum > 140 ? Palette.base : Palette.text;
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
    if (!this.canFocusTerminal()) {
      return;
    }
    const rt: TerminalRuntime | null = this.activeRuntime();
    if (!rt) {
      return;
    }
    // Two independent focus channels must both move to the active tab:
    //  1. ArkUI focus (focusControl) routes the hardware keyboard to its
    //     XComponent — retried because it races the surface's visibility commit.
    //  2. The native IME attachment (process-wide) routes soft-keyboard / CJK
    //     input and raises the keyboard — moved via the controller, exactly like
    //     a tap. Without this, IME text keeps going to the previously tapped tab
    //     and returning from background never re-raises the keyboard.
    console.info('FT_DIAG focusActiveTerminal surfaceId=' + rt.surfaceId);
    this.requestSurfaceFocus(rt.surfaceId, 16);
    rt.controller.focusTerminal();
    // Safety net: if the XComponent still hasn't accepted focus after all retries
    // (e.g. returning from background with a slow window compositor), try once
    // more after a longer delay. Without this, keyboard events leak to other
    // ArkUI elements and Ctrl+key combos may be misrouted.
    setTimeout(() => {
      const currentRt: TerminalRuntime | null = this.activeRuntime();
      if (currentRt && currentRt.surfaceId === rt.surfaceId) {
        try {
          focusControl.requestFocus(rt.surfaceId);
        } catch (_) {}
      }
    }, 500);
  }

  // Don't pull focus to a terminal when an overlay that needs the keyboard is up
  // (connect form, settings sheet, onboarding guide) — e.g. when returning from
  // the background with the connect form open.
  private canFocusTerminal(): boolean {
    return this.tabs.length > 0 && !this.showSettings && !this.showNewConnection && !this.showGuide && !this.showRenameDialog;
  }

  // Requesting focus right after a tab switch or return-to-foreground races the
  // XComponent's visibility/layout commit: the target surface may not be
  // focusable yet, so focusControl.requestFocus() silently fails and keystrokes
  // keep going to the previously focused surface. Retry until it takes, aborting
  // if the active tab changes underneath us (rapid switching).
  private requestSurfaceFocus(surfaceId: string, attempts: number): void {
    setTimeout(() => {
      const rt: TerminalRuntime | null = this.activeRuntime();
      if (!rt || rt.surfaceId !== surfaceId) {
        return;
      }
      let ok: boolean = false;
      try {
        ok = focusControl.requestFocus(surfaceId);
      } catch (_) {
        ok = false;
      }
      if (!ok && attempts > 1) {
        this.requestSurfaceFocus(surfaceId, attempts - 1);
      }
    }, 24);
  }

  private updateTabMeta(id: number, state: DriverState, statusText: string): void {
    const next: TabMeta[] = this.tabs.map((t: TabMeta): TabMeta => {
      if (t.id === id) {
        return new TabMeta(t.id, t.title, state, statusText);
      }
      return new TabMeta(t.id, t.title, t.state, t.statusText);
    });
    this.tabs = next;
  }

  private updateTabTitle(id: number, title: string): void {
    const trimmed = title.trim();
    if (trimmed.length === 0) return;
    const next: TabMeta[] = this.tabs.map((t: TabMeta): TabMeta => {
      if (t.id === id) {
        return new TabMeta(t.id, trimmed, t.state, t.statusText);
      }
      return new TabMeta(t.id, t.title, t.state, t.statusText);
    });
    this.tabs = next;
  }

  // ----- rename dialog --------------------------------------------------------

  private openRenameDialog(id: number): void {
    const t: TabMeta | undefined = this.tabs.find((x: TabMeta) => x.id === id);
    if (t) {
      this.renameTabId = id;
      this.renameText = t.title;
      this.showRenameDialog = true;
    }
  }

  private applyRename(): void {
    const txt: string = this.renameText.trim();
    if (txt.length > 0 && this.renameTabId > 0) {
      console.info('FT_DIAG applyRename id=' + this.renameTabId + ' text=' + txt);
      this.updateTabTitle(this.renameTabId, txt);
      console.info('FT_DIAG applyRename after update: ' + this.tabs.map((t: TabMeta) => t.id + ':' + t.title).join(', '));
    }
    // Delay dismiss so @State tabs commits before bindSheet close animation.
    setTimeout(() => {
      this.closeRenameDialog();
    }, 80);
  }

  private closeRenameDialog(): void {
    this.showRenameDialog = false;
    this.renameTabId = -1;
    this.renameText = '';
    this.hoverMenuAction = '';
  }

  private closeOtherTabs(keepId: number): void {
    const ids: number[] = this.tabs.filter((t: TabMeta) => t.id !== keepId).map((t: TabMeta) => t.id);
    for (let i: number = 0; i < ids.length; i++) {
      this.closeTab(ids[i]);
    }
  }

  // Debounced save — collects the latest snapshot and writes once after 250ms
  // of inactivity. This prevents the race where multiple async saveSession()
  // calls complete out of order and a stale snapshot overwrites the latest one.
  private saveSession(): void {
    if (this.saveDebounceTimer >= 0) {
      clearTimeout(this.saveDebounceTimer);
    }
    this.saveDebounceTimer = setTimeout(() => {
      this.saveDebounceTimer = -1;
      this.doSaveSession();
    }, 250) as number;
  }

  private doSaveSession(): void {
    const store: ConnectionStore | null = this.store;
    if (!store || !this.restoreTabsEnabled) {
      return;
    }
    let activeIndex: number = 0;
    const savedTabs: SavedTab[] = [];
    for (let i: number = 0; i < this.tabs.length; i++) {
      const meta: TabMeta = this.tabs[i];
      if (meta.id === this.activeId) {
        activeIndex = i;
      }
      const rt: TerminalRuntime | undefined = this.runtimes.get(meta.id);
      if (!rt || !rt.connectionConfig) {
        continue;
      }
      savedTabs.push({
        title: meta.title,
        host: rt.connectionConfig.host,
        port: rt.connectionConfig.port,
        token: rt.connectionConfig.token,
        tls: rt.connectionConfig.tls,
        cwd: rt.cwd.length > 0 ? rt.cwd : rt.connectionConfig.cwd,
        shell: rt.connectionConfig.shell,
        sessionId: rt.sessionId.length > 0 ? rt.sessionId : undefined
      });
    }
    store.saveSession({ activeIndex, tabs: savedTabs });
  }

  // Open a new tab and start a session. When overrideConfig is provided
  // (session restore), it uses those params instead of the form fields.
  // initialTitle overrides the default title for session restore.
  private openTab(overrideConfig?: FishConnectConfig, initialTitle?: string): void {
    let host: string;
    let port: number;
    let token: string;
    let tls: boolean;
    let cwd: string | undefined;
    let shell: string | undefined;
    let sessionId: string | undefined;

    if (overrideConfig) {
      host = overrideConfig.host;
      port = overrideConfig.port;
      token = overrideConfig.token;
      tls = overrideConfig.tls;
      cwd = overrideConfig.cwd;
      shell = overrideConfig.shell;
      sessionId = overrideConfig.sessionId;
    } else {
      host = this.host.trim();
      token = this.token.trim();
      port = Number(this.port);
      tls = this.tls;
      if (host.length === 0 || !Number.isInteger(port) || port <= 0 || port > 65535 || token.length === 0) {
        this.formError = '请先填写连接信息';
        return;
      }
    }

    const id: number = this.nextId++;
    const rt: TerminalRuntime = new TerminalRuntime(id);
    this.applySettingsTo(rt.controller);
    this.runtimes.set(id, rt);

    const cfg: FishConnectConfig = { host, port, token, tls, cwd, shell, sessionId };
    rt.connectionConfig = cfg;
    if (cwd) {
      rt.cwd = cwd;
    }
    if (sessionId) {
      rt.sessionId = sessionId;
    }

    const tabTitle: string = initialTitle ?? ((cwd && cwd.length > 0)
      ? (cwd.split('/').pop() || ('终端 ' + id))
      : ('终端 ' + id));
    const meta: TabMeta = new TabMeta(id, tabTitle, DriverState.Connecting, '连接中…');
    this.tabs = this.tabs.concat(meta);
    this.activeId = id;

    const session: TerminalSession = new TerminalSession(rt.controller, new FishWebSocketDriver(cfg));
    session.onStatus((s: DriverStatus): void => {
      this.updateTabMeta(id, s.state, stateLabel(s));
      this.saveSession();
    });
    session.onTitleChange((title: string): void => {
      this.updateTabTitle(id, title);
      this.saveSession();
    });
    session.onCwdChange((dir: string): void => {
      rt.cwd = dir;
      this.saveSession();
    });
    session.onSessionId((id: string): void => {
      rt.sessionId = id;
      this.saveSession();
    });
    rt.session = session;
    session.start();
    this.focusActiveTerminal();
    this.saveSession();
    // Native bind happens in the surface's onLoad; poll briefly so the tab/
    // content background can pick up the real theme bg once it's available.
    setTimeout(() => { this.refreshThemeBg(); }, 250);
    this.startLiveBgPolling();
  }

  private switchTab(id: number): void {
    if (id === this.activeId) {
      this.focusActiveTerminal();
      return;
    }
    this.activeId = id;
    this.focusActiveTerminal();
    this.saveSession();
    // Immediately sync the background — the new active tab may have different
    // colors (e.g. opencode altered its background via OSC).
    setTimeout(() => { this.syncLiveBackground(); }, 100);
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
      if (this.tabs.length === 0) {
        this.stopLiveBgPolling();
      }
      this.saveSession();
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

  private applyLineSpacing(spacing: number): void {
    this.lineSpacing = clampLineSpacing(spacing);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveLineSpacing(this.lineSpacing);
    }
  }

  private applyUIFontFamily(family: string): void {
    this.uiFontFamily = family;
    if (this.store) {
      this.store.saveFontFamily(family, true);
    }
  }

  private applyTermFontFamily(family: string): void {
    this.termFontFamily = family;
    this.broadcastConfig();
    if (this.store) {
      this.store.saveFontFamily(family, false);
    }
  }

  private applyFontScaleBoost(value: number): void {
    this.fontScaleBoost = clampFontScaleBoost(value);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveFontScaleBoost(this.fontScaleBoost);
    }
  }

  private applyCjkVerticalOffset(value: number): void {
    this.cjkVerticalOffset = clampCjkVerticalOffset(value);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveCjkVerticalOffset(this.cjkVerticalOffset);
    }
  }

  private applyCharacterSpacing(value: number): void {
    this.characterSpacing = clampCharacterSpacing(value);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveCharacterSpacing(this.characterSpacing);
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
          .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 10, bottomRight: 10 })
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
        onDisappear: () => {
          // Reset the flag even when dismissed via swipe / back gesture rather
          // than the explicit Close button, so canFocusTerminal() won't block
          // future focusActiveTerminal() calls (the "Ctrl clears input" bug).
          this.showSettings = false;
          this.focusActiveTerminal();
        }
      })

      // Invisible anchor for the crash log sheet — third bindSheet because
      // a component can only host one bindSheet. Animation identical to settings.
      Text('')
        .width(0).height(0)
        .bindSheet($$this.showCrashLog, this.buildCrashLogSheet(), {
          preferType: SheetType.CENTER,
          width: '50%',
          dragBar: false,
          showClose: false,
          backgroundColor: Palette.base,
          onDisappear: () => {
            this.showCrashLog = false;
            this.focusActiveTerminal();
          }
        })
      // Invisible anchor for the rename sheet.
      Text('')
        .width(0).height(0)
        .bindSheet($$this.showRenameDialog, this.buildRenameSheet(), {
          preferType: SheetType.CENTER,
          width: '30%',
          height: 220,
          dragBar: false,
          showClose: false,
          backgroundColor: Palette.base,
          onDisappear: () => {
            this.showRenameDialog = false;
            this.focusActiveTerminal();
          }
        })

      if (this.restoreChecked && (this.tabs.length === 0 || this.showNewConnection)) {
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
    // App-level keyboard shortcuts. All use Ctrl+Shift to avoid conflicting
    // with: (a) terminal escape sequences that use bare Ctrl (Ctrl+W, Ctrl+T,
    // Ctrl+1~9 are meaningful to shells/readline); (b) IME mode-switch keys
    // that many Chinese input methods assign to Ctrl combinations.
    .keyboardShortcut('f', [ModifierKey.CTRL, ModifierKey.SHIFT], () => { this.requestSearch(); })
    .keyboardShortcut('t', [ModifierKey.CTRL, ModifierKey.SHIFT], () => { this.openTab(); })
    .keyboardShortcut('w', [ModifierKey.CTRL, ModifierKey.SHIFT], () => { this.closeTab(this.activeId); })
    .keyboardShortcut(FunctionKey.TAB, [ModifierKey.CTRL], () => { this.cycleTab(1); })
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
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.activeMeta().state !== DriverState.Connecting) {
          Text('立即重连')
            .fontSize(12)
            .fontFamily(this.uiFontFamily)
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
          }, (tab: TabMeta) => tab.id + '_' + tab.title)

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
      .onClick(() => { this.openGuide(); })

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
      Text(tab.title)
        .fontSize(Math.max(10, this.fontSize - 1))
        .fontFamily(this.uiFontFamily)
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
    .bindContextMenu(this.buildTabContextMenu(tab), ResponseType.RightClick)
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

  @Builder
  private buildTabContextMenu(tab: TabMeta) {
    Column() {
      // 重命名
      Row({ space: 8 }) {
        Text('✎')
          .fontSize(12)
          .fontColor(Palette.textDim)
        Text('重命名')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'rename' ? '#14FFFFFF' : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'rename' : ''; })
      .onClick(() => { this.openRenameDialog(tab.id); })

      // Separator with horizontal margins
      Divider().color(Palette.border).width('100%').margin({ left: 8, right: 8 })

      // 关闭其他
      Row({ space: 8 }) {
        Text('✕')
          .fontSize(12)
          .fontColor(Palette.textDim)
        Text('关闭其他标签页')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'close_others' ? '#1FFFFB454' : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'close_others' : ''; })
      .onClick(() => { this.closeOtherTabs(tab.id); })

      // Separator
      Divider().color(Palette.border).width('100%').margin({ left: 8, right: 8 })

      // 关闭
      Row({ space: 8 }) {
        Text('✕')
          .fontSize(12)
          .fontColor(Palette.textDim)
        Text('关闭')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'close' ? '#1FFF6B6B' : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'close' : ''; })
      .onClick(() => { this.closeTab(tab.id); })
    }
    .width(160)
    .padding(4)
    .backgroundColor(Palette.surface)
    .borderRadius(8)
    .border({ width: 1, color: Palette.border })
    .shadow({ radius: 12, color: '#66000000', offsetY: 6 })
  }

  private activeMeta(): TabMeta {
    for (let i: number = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.activeId) {
        return this.tabs[i];
      }
    }
    return new TabMeta(-1, '', DriverState.Idle, '空闲');
  }

  // Rename sheet — bindSheet(CENTER) native animation, matching settings panel style.
  @Builder
  private buildRenameSheet() {
    Column({ space: 14 }) {
      Text('重命名标签页')
        .fontSize(17)
        .fontFamily(this.uiFontFamily)
        .fontColor(Palette.text)
        .fontWeight(FontWeight.Medium)
        .width('100%')
      TextInput({ text: $$this.renameText, placeholder: '输入标签页名称' })
        .fontSize(14)
        .fontFamily(this.uiFontFamily)
        .fontColor(Palette.text)
        .placeholderColor(Palette.textDim)
        .backgroundColor(Palette.inputBg)
        .borderRadius(7)
        .border({ width: 1, color: Palette.accent })
        .height(42)
        .width('100%')
        .defaultFocus(true)
      // Buttons
      Row({ space: 10 }) {
        Row() {
          Text('取消')
            .fontSize(13)
            .fontFamily(this.uiFontFamily)
            .fontColor(Palette.text)
        }
        .height(38)
        .layoutWeight(1)
        .borderRadius(7)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.border)
        .focusable(false)
        .onClick(() => { this.closeRenameDialog(); })
        Row() {
          Text('确认')
            .fontSize(13)
            .fontFamily(this.uiFontFamily)
            .fontColor(Palette.base)
        }
        .height(38)
        .layoutWeight(1)
        .borderRadius(7)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.accent)
        .focusable(false)
        .onClick(() => { this.applyRename(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
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
      lineSpacing: this.lineSpacing,
      initialTab: this.settingsInitialTab,
      statusText: this.activeMeta().statusText,
      statusColor: this.dotColor(this.activeMeta().state),
      hostLabel: this.host + ':' + this.port,
      themeName: this.themeName,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink,
      scrollbackLines: this.scrollbackLines,
      uiFontFamily: this.uiFontFamily,
      termFontFamily: this.termFontFamily,
      fontScaleBoost: this.fontScaleBoost,
      cjkVerticalOffset: this.cjkVerticalOffset,
      characterSpacing: this.characterSpacing,
      onThemeChange: (n: string) => { this.themeName = n; this.broadcastTheme(); },
      onCursorStyleChange: (v: number) => { this.cursorStyle = v; this.broadcastConfig(); },
      onCursorBlinkChange: (v: boolean) => { this.cursorBlink = v; this.broadcastConfig(); },
      onScrollbackChange: (v: number) => { this.scrollbackLines = v; this.broadcastConfig(); },
      onFontSizeChange: (s: number) => { this.applyFontSize(s); },
      onLineSpacingChange: (s: number) => { this.applyLineSpacing(s); },
      onUIFontFamilyChange: (f: string) => { this.applyUIFontFamily(f); },
      onTermFontFamilyChange: (f: string) => { this.applyTermFontFamily(f); },
      onFontScaleBoostChange: (v: number) => { this.applyFontScaleBoost(v); },
      onCjkVerticalOffsetChange: (v: number) => { this.applyCjkVerticalOffset(v); },
      onCharacterSpacingChange: (v: number) => { this.applyCharacterSpacing(v); },
      onReplayGuide: () => { this.showSettings = false; this.openGuide(); },
      onClose: () => { this.showSettings = false; }
    })
  }

  // ----- onboarding guide ----------------------------------------------------

  private readonly guideCount: number = 5;

  private guideTitle(step: number): string {
    switch (step) {
      case 0: return '欢迎使用 fish-term';
      case 1: return '第 1 步 · 安装 fish-agent';
      case 2: return '第 2 步 · 启动服务 & 获取连接信息';
      case 3: return '第 3 步 · 新建连接';
      default: return '第 4 步 · 开始使用';
    }
  }

  private guideDesc(step: number): string {
    switch (step) {
      case 0:
        return 'fish-term 是一个连接到 fish-agent 的 HarmonyOS 终端。\n只需几步就能在手机/平板上获得完整的远程终端体验。';
      case 1:
        return 'fish-agent 基于 wand-agent 修改，是一个 Go 编写的 WebSocket PTY 代理。\n\n安装方式一：下载预编译二进制（Linux）\n\n  # ARM64（树莓派/ARM 服务器）\n  curl -LO https://github.com/<repo>/releases/latest/download/fish-agent-linux-arm64\n\n  # x86_64（普通 PC/服务器）\n  curl -LO https://github.com/<repo>/releases/latest/download/fish-agent-linux-amd64\n\n  chmod +x fish-agent-linux-*\n\n安装方式二：从源码编译\n\n  git clone <repo-url> && cd fish-agent\n  go build -buildvcs=false -o fish-agent .\n\n编译完成后将 fish-agent 复制到任意目录即可运行。';
      case 2:
        return '启动 fish-agent：\n\n  ./fish-agent --host 0.0.0.0 --port 8765 --token <你的token>\n\n参数说明：\n  --host  监听地址，默认 0.0.0.0（所有网卡）\n  --port  监听端口，默认 8765\n  --token  鉴权令牌，客户端连接时需携带\n\n启动后会输出 host、port、token 三项信息。\n用 ip addr 查看服务器 IP，确保设备和服务器在同一网络可达。\n如开启防火墙，请放行对应端口。';
      case 3:
        return '回到 fish-term，在首页填入 host / 端口 / token，\n如需加密传输可打开 TLS(wss)，点击「连接」即可开启第一个终端标签页。';
      default:
        return '常用操作：\n\n  · 右键终端：复制 / 粘贴 / 查找 / 缓冲区\n  · Ctrl+Shift+F：查找\n  · Ctrl+Shift+T 新建标签，Ctrl+Shift+W 关闭，Ctrl+Tab 切换\n  · 标签可拖拽排序；设置里可换主题、字号、光标样式';
    }
  }

  // Placeholder filename for the screenshot to drop in for each step.
  private guideImageName(step: number): string {
    return 'guide_' + step + '.png';
  }

  // Navigate the guide. The native Tabs slide animation handles the motion;
  // direction is automatic (forward vs back). Past the last step it finishes.
  private goStep(dir: number): void {
    const target: number = this.guideStep + dir;
    if (target >= this.guideCount) {
      this.finishGuide();
      return;
    }
    if (target < 0) {
      return;
    }
    this.guideTabs.changeIndex(target);
  }

  // One guide page (image + title + description), inside a Scroll so a tall
  // page (e.g. the shortcuts summary) can scroll within the fixed Tabs height.
  // The image is pinned to the top of the scroll area so its top edge stays at
  // the same position across all steps during horizontal swipe.
  @Builder
  private guideBody(step: number) {
    Scroll() {
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
        .margin({ top: 0, bottom: 18 })

        Text(this.guideTitle(step))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
          .width('100%')
          .margin({ bottom: 10 })

        Text(this.guideDesc(step))
          .fontSize(14)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.textDim)
          .lineHeight(22)
          .width('100%')
      }
      .width('100%')
      .padding({ top: 0 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .align(Alignment.Top)
  }

  @Builder
  private buildGuide() {
    Stack({ alignContent: Alignment.Center }) {
      // Background mask — fades in/out independently via guideBgOpacity.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .opacity(this.guideBgOpacity * 0.8)
        .onClick(() => { /* absorb clicks, close on background tap disabled */ })

      // Card
      Column() {
        // Sliding page area: native Tabs gives a smooth horizontal slide. Swipe
        // between pages is also enabled. Native bar hidden; buttons/dots drive it.
        Tabs({ controller: this.guideTabs, index: this.guideStep }) {
          TabContent() { this.guideBody(0) }
          TabContent() { this.guideBody(1) }
          TabContent() { this.guideBody(2) }
          TabContent() { this.guideBody(3) }
          TabContent() { this.guideBody(4) }
        }
        .barHeight(0)
        .scrollable(true)
        .animationDuration(300)
        .width('100%')
        .height(320)
        .onChange((i: number) => { this.guideStep = i; })

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
      // Slide-up + fade transition matching bindSheet(CENTER) feel.
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.translate({ y: 60 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 280, curve: this.guideAnimCurve }),
        TransitionEffect.translate({ y: 60 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 250, curve: this.guideAnimCurve })
      ))
    }
    .width('100%')
    .height('100%')
    .padding(24)
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
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
        Text('connect to fish-agent')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
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

  @Builder
  private buildCrashLogSheet() {
    CrashLogPanel({
      entry: this.crashEntry,
      onClose: () => { this.showCrashLog = false; },
      onViewed: (id: string) => {
        if (this.context) {
          const store = new CrashStore(this.context);
          store.markViewed(id);
        }
      },
      onDontShowAgain: () => {
        if (this.store) {
          this.store.saveShowCrashOnStartup(false);
        }
      }
    })
  }
}
