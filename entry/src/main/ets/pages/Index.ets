import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { font, window } from '@kit.ArkUI';
import { TerminalController, TerminalSurface } from 'libghostty_ohos';
import { TerminalSession } from '../session/TerminalSession';
import { TerminalRuntime } from '../session/TerminalTab';
import { FishWebSocketDriver } from '../transport/FishWebSocketDriver';
import { DriverState, DriverStatus, FishConnectConfig } from '../transport/TerminalDriver';
import { ConnectionStore, ConnectionProfile, TerminalPrefs, DEFAULT_TERMINAL_PREFS, SavedSession, SavedTab } from '../store/ConnectionStore';
import { UiTheme, UiThemeStore, REFINED_DARK_THEME, RADIUS_CARD, RADIUS_CONTROL, toSurfaceTheme } from '../theme/UiTheme';
import {
  DEFAULT_FONT_SIZE, clampFontSize,
  DEFAULT_LINE_SPACING, clampLineSpacing,
  DEFAULT_UI_FONT, DEFAULT_TERM_FONT,
  DEFAULT_FONT_SCALE_BOOST, DEFAULT_CJK_VERTICAL_OFFSET, DEFAULT_CHARACTER_SPACING,
  clampFontScaleBoost, clampCjkVerticalOffset, clampCharacterSpacing
} from '../theme/FontScale';
import { SettingsPanel } from './SettingsPanel';
import { CrashLogPanel } from './CrashLogPanel';
import { TabStrip, TabMeta } from '../components/TabStrip';
import { StatusBanner, BannerKind } from '../components/StatusBanner';
import { ConnectionForm } from '../components/ConnectionForm';
import { GuideOverlay } from '../components/GuideOverlay';
import { CrashHandler } from '../crash/CrashHandler';
import { CrashType, CrashLogEntry } from '../crash/CrashTypes';
import { CrashStore } from '../crash/CrashStore';
import { TaskEvent } from '../notifications/TaskEvent';
import { TaskDetector } from '../notifications/TaskDetector';
import { NotificationService } from '../notifications/NotificationService';
import { NotificationPrefs, DEFAULT_NOTIFICATION_PREFS } from '../store/ConnectionStore';

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

// TabMeta lives in components/TabStrip.ets now (exported @Observed class,
// imported above) — fields unchanged: id/title/state/statusText.

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
  @State private renameTabId: number = -1;
  @State private renameText: string = '';
  @State private showRenameDialog: boolean = false;
  @State private host: string = '192.168.1.10';
  @State private port: string = '8765';
  @State private token: string = '';
  @State private tls: boolean = false;
  @State private rememberToken: boolean = false;
  @State private fontSize: number = DEFAULT_FONT_SIZE;
  @State private lineSpacing: number = DEFAULT_LINE_SPACING;
  @State private formError: string = '';
  @State private showSettings: boolean = false;
  @State private settingsInitialTab: number = 0;
  @State private showNewConnection: boolean = false;
  @State private themeName: string = 'Aizen_Dark';
  // Real bg/fg colors of the current theme, refreshed after native bind.
  // Used to match the active tab chip and content card precisely so they
  // fuse visually — even when the user picks a light theme.
  @State private themeBg: string = REFINED_DARK_THEME.bgBase;
  @State private themeFg: string = REFINED_DARK_THEME.textPrimary;
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
  @State private tabCompact: boolean = false;
  @State private showCrashLog: boolean = false;
  @State private crashEntry: CrashLogEntry = {
    id: '', timestamp: 0, crashType: CrashType.JS_CRASH,
    summary: '', stackTrace: '', systemLog: '',
    deviceInfo: { deviceModel: '', osVersion: '', appVersion: '' },
    logFileName: '', viewed: false
  };
  // chipWidths / tabScroller are passed to TabStrip by reference (plain member
  // params) — the strip measures chips into this same Map and attaches this
  // same Scroller, so scrollToTab() and the wheel handler below keep working.
  private chipWidths: Map<number, number> = new Map<number, number>();
  private tabScroller: Scroller = new Scroller();
  @State private showOverflow: boolean = false;
  private saveDebounceTimer: number = -1;
  private detector: TaskDetector = new TaskDetector();
  private notifyService: NotificationService = new NotificationService();
  @State private notifyPrefs: NotificationPrefs = DEFAULT_NOTIFICATION_PREFS;
  @State private isForeground: boolean = true;
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new ConnectionStore(this.context);

    // Load persisted UI scheme before first content frame (splash is still showing).
    this.store.loadUiScheme().then((scheme: string): void => {
      UiThemeStore.setScheme(scheme === 'futuristic' ? 'futuristic' : 'refined');
    });

    // Initialize notification service with app context
    this.notifyService.setContext(this.context);

    // Load notification preferences
    if (this.store) {
      this.store.loadNotificationPrefs().then((prefs: NotificationPrefs): void => {
        this.notifyPrefs = prefs;
        this.notifyService.updatePrefs(prefs);
        this.detector.bellEnabled = prefs.bellEnabled;
      });
    }

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
    // Defer tab restore to a macrotask so the first frame can render the
    // startup loading indicator before Promise callbacks block the thread.
    // Without this, all microtasks (preferences reads → openTab() × N)
    // complete before the first paint and the loading UI never appears.
    setTimeout(() => { this.loadRestoreTabsAndRestore(); }, 10);
    emitter.on({ eventId: 10086 }, () => {
      this.isForeground = true;
      this.runtimes.forEach((rt: TerminalRuntime) => {
        rt.session?.onForeground();
      });
      this.focusActiveTerminal();
    });
    emitter.on({ eventId: 10087 }, () => {
      this.isForeground = false;
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
      store.loadTabCompact().then((v: boolean): void => {
        this.tabCompact = v;
      });
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

        // Restore tabs one at a time via setTimeout, yielding the main thread
        // between each so the loading indicator stays animated and the system
        // doesn't flag the app as unresponsive (ANR).
        let ri: number = 0;
        const restoreNext = (): void => {
          if (ri >= session.tabs.length) {
            // All tabs created — finalize.
            if (session.activeIndex >= 0 && session.activeIndex < this.tabs.length) {
              this.activeId = this.tabs[session.activeIndex].id;
              this.focusActiveTerminal();
            }
            // Delay revealing the tab strip so native terminal surfaces have
            // time to mount their renderers and draw the first frame.  Without
            // this the user sees a brief flash of black surfaces and status
            // banners between the loading indicator and the first content.
            setTimeout(() => {
              this.restoreChecked = true;
              // Re-apply saved titles after another short delay to survive any
              // async callbacks that fire during session startup (status events,
              // OSC title detection, etc.).
              setTimeout(() => {
                for (let i: number = 0; i < this.tabs.length && i < session.tabs.length; i++) {
                  const savedTitle: string = session.tabs[i].title;
                  if (savedTitle.length > 0) {
                    this.updateTabTitle(this.tabs[i].id, savedTitle);
                  }
                }
              }, 500);
            }, 400);
            return;
          }
          const t: SavedTab = session.tabs[ri];
          this.openTab({
            host: t.host,
            port: t.port,
            token: t.token,
            tls: t.tls,
            cwd: t.cwd,
            shell: t.shell,
            sessionId: t.sessionId
          }, t.title);
          ri++;
          setTimeout(restoreNext, 10);
        };
        restoreNext();
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
    store.loadTabCompact().then((v: boolean): void => {
      this.tabCompact = v;
    });
  }

  // Guide appear/disappear animation lives in GuideOverlay now (mask fade on
  // mount + card TransitionEffect); the page only toggles visibility.
  private openGuide(): void {
    this.showGuide = true;
  }

  // Called via GuideOverlay.onFinish (skip / past last step). The overlay's
  // 250ms mask fade-out runs alongside the card exit transition; persist the
  // onboarded flag after the animation, as the old closeGuide() did.
  private finishGuide(): void {
    this.showGuide = false;
    setTimeout(() => {
      if (this.store) {
        this.store.saveOnboarded(true);
      }
    }, 260);
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
    this.notifyService.dismissAll();
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
    return lum > 140 ? REFINED_DARK_THEME.bgBase : REFINED_DARK_THEME.textPrimary;
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
    // Primary retry wave — 20 attempts × 50ms = 1 000ms coverage.
    this.requestSurfaceFocus(rt.surfaceId, 20);
    rt.controller.focusTerminal();
    // Secondary wave: starts after a 600ms delay (once the primary wave has run
    // ~12 of its 20 attempts) and overlaps with the tail of the primary wave,
    // then continues for another 500ms after the primary finishes. Together they
    // cover ~1 500ms, which is enough for the slowest return-from-background
    // surface restore paths observed on HarmonyOS devices.
    setTimeout(() => {
      const currentRt: TerminalRuntime | null = this.activeRuntime();
      if (currentRt && currentRt.surfaceId === rt.surfaceId) {
        this.requestSurfaceFocus(rt.surfaceId, 10);
      }
    }, 600);
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
  //
  // IMPORTANT: focusControl.requestFocus() on HarmonyOS may return true without
  // actually establishing focus (false positive). Always retry for the full
  // attempt count regardless of the return value — never trust a single
  // true/false. 20 retries × 50ms = 1 000ms coverage, which gives the ArkUI
  // render pipeline and the native XComponent surface enough time to settle
  // after visibility transitions and return-from-background restore.
  private requestSurfaceFocus(surfaceId: string, attempts: number): void {
    setTimeout(() => {
      const rt: TerminalRuntime | null = this.activeRuntime();
      if (!rt || rt.surfaceId !== surfaceId) {
        return;
      }
      try {
        focusControl.requestFocus(surfaceId);
      } catch (_) {
        // best-effort — we retry regardless
      }
      const remaining: number = attempts - 1;
      if (remaining > 0) {
        this.requestSurfaceFocus(surfaceId, remaining);
      }
    }, 50);
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

  // Called when TaskDetector detects a task state change.
  // Delegates to NotificationService for system notification (background only via prefs).
  private handleTaskEvent(event: TaskEvent): void {
    console.info(`[Index] TaskEvent: tab=${event.tabId} type=${event.type} detail=${event.detail}`);
    this.notifyService.handle(event, this.isForeground);
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
    // NOTE: the context-menu hover reset that used to live here moved into
    // TabStrip (it owns hoverMenuAction now; it resets on the rename click).
  }

  private closeOtherTabs(keepId: number): void {
    const ids: number[] = this.tabs.filter((t: TabMeta) => t.id !== keepId).map((t: TabMeta) => t.id);
    for (let i: number = 0; i < ids.length; i++) {
      this.closeTab(ids[i]);
    }
  }

  // Splice one tab from index `from` to index `to`. Called by TabStrip's live
  // drag-reorder (onReorder) — the strip tracks the dragged chip's pending
  // index and fires this once per crossed slot, exactly like the old
  // moveDragged() did when it lived here.
  private reorderTabs(from: number, to: number): void {
    if (from < 0 || from >= this.tabs.length || to < 0 || to >= this.tabs.length || from === to) {
      return;
    }
    const list: TabMeta[] = this.tabs.slice();
    const moved: TabMeta = list.splice(from, 1)[0];
    list.splice(to, 0, moved);
    this.tabs = list;
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
    // Wire task detector to session output for notification analysis
    const tabId: number = id;
    const tabTitleRef: string = tabTitle;
    session.onTaskData((data: string): void => {
      const event: TaskEvent | null = this.detector.detect(data, tabId, tabTitleRef);
      if (event !== null) {
        // Update the event with the current tab title (may have changed via OSC)
        const t: TabMeta | undefined = this.tabs.find((x: TabMeta) => x.id === tabId);
        if (t) {
          event.tabTitle = t.title;
        }
        this.handleTaskEvent(event);
      }
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
      this.notifyService.dismiss(id);
      this.focusActiveTerminal();
      return;
    }
    this.activeId = id;
    // Dismiss notification for the newly active tab
    this.notifyService.dismiss(id);
    this.focusActiveTerminal();
    this.saveSession();
    // Immediately sync the background — the new active tab may have different
    // colors (e.g. opencode altered its background via OSC).
    setTimeout(() => { this.syncLiveBackground(); }, 100);
    // Auto-scroll the tab strip so the newly active chip is visible.
    if (!this.tabCompact) {
      setTimeout(() => { this.scrollToTab(id); }, 50);
    }
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

  // Scroll the tab strip horizontally so that the chip for `id` is visible.
  // Used after keyboard-switch (Ctrl+Tab / Ctrl+1..9) and overflow-menu clicks.
  private scrollToTab(id: number): void {
    const index: number = this.tabs.findIndex((t: TabMeta) => t.id === id);
    if (index < 0) {
      return;
    }
    // Approximate offset: each chip width averaged, plus gaps.
    const chipW: number = this.avgChipWidth();
    const gap: number = 4;
    const targetX: number = index * (chipW + gap);
    // Scroll so the chip lands near the left edge with a little padding.
    this.tabScroller.scrollTo({ xOffset: Math.max(0, targetX - chipW), yOffset: 0, animation: true });
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
    this.notifyService.dismiss(id);

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
        return this.uiTheme.accent;
      case DriverState.Connecting:
      case DriverState.Reconnecting:
        return this.uiTheme.warn;
      case DriverState.Error:
        return this.uiTheme.danger;
      default:
        return this.uiTheme.textDim;
    }
  }

  build() {
    Stack() {
      if (!this.restoreChecked) {
        // Startup loading — full-screen centered indicator shown while reading
        // saved sessions from preferences and restoring connections.  Stays
        // visible until ALL tabs are created, not just the first one.
        Column() {
          Column({ space: 16 }) {
            Image($r('app.media.app_logo'))
              .width(72)
              .height(72)
              .borderRadius(16)

            LoadingProgress()
              .width(32)
              .height(32)
              .color(this.uiTheme.accent)

            Text('连接中...')
              .fontSize(15)
              .fontFamily(this.uiFontFamily)
              .fontColor(this.uiTheme.textDim)
          }
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.uiTheme.bgBase)
      } else {
        Column() {
          if (this.tabs.length > 0) {
            TabStrip({
              tabs: this.tabs,
              activeId: this.activeId,
              themeBg: this.themeBg,
              themeFg: this.themeFg,
              tabCompact: this.tabCompact,
              fontSize: this.fontSize,
              uiFontFamily: this.uiFontFamily,
              statusText: this.activeStatusText(),
              statusColor: this.activeStatusColor(),
              showStatusCapsule: this.activeTabConnected(),
              tabScroller: this.tabScroller,
              chipWidths: this.chipWidths,
              onSwitchTab: (id: number): void => { this.switchTab(id); },
              onCloseTab: (id: number): void => { this.closeTab(id); },
              // Preserve the old "+" behavior: open a tab directly with the
              // current form values (brief's snippet said showNewConnection —
              // deliberately NOT followed, behavior must not change).
              onNewTab: (): void => { this.openTab(); },
              onReorder: (from: number, to: number): void => { this.reorderTabs(from, to); },
              onRenameTab: (id: number): void => { this.openRenameDialog(id); },
              onCloseOthers: (id: number): void => { this.closeOtherTabs(id); },
              onOpenGuide: (): void => { this.openGuide(); },
              onOpenSettings: (): void => { this.openSettings(); },
              onOpenAbout: (): void => { this.settingsInitialTab = 3; this.showSettings = true; },
              onOpenOverflow: (): void => { this.showOverflow = !this.showOverflow; }
            })
            // Terminal content as a rounded card. The frame (bgChrome,
            // same color as the strip) shows on left/right/bottom because the
            // parent Column pads those sides. Cross-axis stretch fills the rest,
            // so no width('100%') is set (that would overflow the padding and
            // clip the right border).
            // Task 6: the card is now a Column whose first child is the scheme-B
            // signature line (accent→accentAlt gradient). Under refined the line
            // is fully transparent and the card radius is RADIUS_CARD on all
            // corners, so pixels match the pre-Task-6 baseline. The terminal
            // background stays themeBg-driven (terminal theme, not a chrome token).
            Column() {
              Row()
                .width('100%')
                .height(2)
                .linearGradient({ angle: 0, colors: [[this.uiTheme.accent, 0.0], [this.uiTheme.accentAlt, 1.0]] })
                .opacity(this.uiTheme.accentGradient ? 1 : 0)
                .borderRadius({ topLeft: RADIUS_CARD, topRight: RADIUS_CARD })
              Stack({ alignContent: Alignment.Top }) {
                ForEach(this.tabs, (tab: TabMeta) => {
                  this.buildSurface(tab.id);
                }, (tab: TabMeta) => tab.id.toString())
                StatusBanner({
                  visible: this.bannerVisible(),
                  text: this.activeMeta().statusText,
                  kind: this.bannerKind(),
                  // No manual reconnect while the first connect is still in
                  // flight — matches the old `state !== Connecting` check.
                  actionText: this.activeMeta().state === DriverState.Connecting ? '' : '立即重连',
                  uiFontFamily: this.uiFontFamily,
                  onAction: (): void => { this.reconnectActive(); }
                })
              }
              .width('100%')
              .layoutWeight(1)
            }
            .layoutWeight(1)
            .backgroundColor(this.themeBg)
            .borderRadius(this.uiTheme.accentGradient
              ? { topLeft: 0, topRight: 0, bottomLeft: RADIUS_CARD, bottomRight: RADIUS_CARD } as BorderRadiuses
              : RADIUS_CARD)
            .clip(true)
          }
        }
        .width('100%')
        .height('100%')
        // Frame: bgChrome border on left / right / bottom. The top frame
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
          backgroundColor: this.uiTheme.bgBase,
          onDisappear: () => {
            // Reset the flag even when dismissed via swipe / back gesture rather
            // than the explicit Close button, so canFocusTerminal() won't block
            // future focusActiveTerminal() calls (the "Ctrl clears input" bug).
            this.showSettings = false;
            this.focusActiveTerminal();
          }
        })
      }

      // Invisible anchor for the crash log sheet — third bindSheet because
      // a component can only host one bindSheet. Animation identical to settings.
      Text('')
        .width(0).height(0)
        .bindSheet($$this.showCrashLog, this.buildCrashLogSheet(), {
          preferType: SheetType.CENTER,
          width: '50%',
          dragBar: false,
          showClose: false,
          backgroundColor: this.uiTheme.bgBase,
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
          backgroundColor: this.uiTheme.bgBase,
          onDisappear: () => {
            this.showRenameDialog = false;
            this.focusActiveTerminal();
          }
        })

      if (this.restoreChecked && (this.tabs.length === 0 || this.showNewConnection)) {
        ConnectionForm({
          host: $this.host,
          port: $this.port,
          token: $this.token,
          tls: $this.tls,
          rememberToken: $this.rememberToken,
          formError: $this.formError,
          uiFontFamily: this.uiFontFamily,
          showNewConnection: this.showNewConnection,
          onConnect: (): void => { this.connectFromForm(); },
          onCancel: (): void => { this.showNewConnection = false; this.focusActiveTerminal(); }
        })
      }

      // Overflow menu overlay — tab list dropdown
      if (this.showOverflow) {
        // Semi-transparent backdrop — tap anywhere to dismiss
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .focusable(false)
          .onClick(() => { this.showOverflow = false; })
        // Dropdown panel anchored near the right side of the tab strip
        Column({ space: 0 }) {
          Scroll() {
            Column({ space: 2 }) {
              ForEach(this.tabs, (tab: TabMeta) => {
                this.buildOverflowItem(tab)
              }, (tab: TabMeta) => 'overflow_' + tab.id)
            }
            .width('100%')
            .padding(4)
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .constraintSize({ maxHeight: 320 })
          .width('100%')
        }
        .width(200)
        .backgroundColor(this.uiTheme.bgSurface)
        .borderRadius(RADIUS_CONTROL)
        .border({ width: 1, color: this.uiTheme.border })
        .shadow({ radius: 12, color: this.uiTheme.shadowCard, offsetY: 6 })
        .position({ right: 140, top: 40 })
        .zIndex(100)
      }

      if (this.showGuide) {
        GuideOverlay({
          uiFontFamily: this.uiFontFamily,
          onFinish: (): void => { this.finishGuide(); }
        })
      }
    }
    .width('100%')
    .height('100%')
    // Frame color matches the strip — forms a consistent border on
    // left / right / bottom of the terminal card.
    .backgroundColor(this.uiTheme.bgChrome)
    // Mouse-wheel horizontal scroll for the tab strip (non-compact only).
    // Captured at the root Stack because the Scroll component consumes axis
    // events internally and their onAxisEvent is unreliable. We filter by
    // y < 40 so only wheel events over the tab strip are intercepted.
    .onAxisEvent((event?: AxisEvent) => {
      if (event && !this.tabCompact && this.tabs.length > 0) {
        const localY: number = event.y;
        if (localY >= 0 && localY <= 40) {
          const dy: number = event.getVerticalAxisValue();
          if (Math.abs(dy) > 0) {
            this.tabScroller.scrollBy(dy, 0);
          }
        }
      }
    })
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
      surfaceTheme: toSurfaceTheme(this.uiTheme),
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

  private activeMeta(): TabMeta {
    for (let i: number = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.activeId) {
        return this.tabs[i];
      }
    }
    return new TabMeta(-1, '', DriverState.Idle, '空闲');
  }

  // ----- helpers feeding the extracted components -----------------------------

  private openSettings(): void {
    this.settingsInitialTab = 0;
    this.showSettings = true;
  }

  // Status props for TabStrip's status capsule (rendered in Task 6) — derived
  // from the active tab exactly like the settings sheet's status props.
  private activeStatusText(): string {
    return this.activeMeta().statusText;
  }

  private activeStatusColor(): string {
    return this.dotColor(this.activeMeta().state);
  }

  private activeTabConnected(): boolean {
    return this.activeMeta().state === DriverState.Connected;
  }

  // StatusBanner mapping: the banner shows while the active tab is not
  // connected; kind maps Connecting/Reconnecting → 'warn', Error/Closed →
  // 'danger', everything else → 'info'.
  private bannerVisible(): boolean {
    const state: DriverState = this.activeMeta().state;
    return state === DriverState.Reconnecting
      || state === DriverState.Error
      || state === DriverState.Connecting;
  }

  private bannerKind(): BannerKind {
    const state: DriverState = this.activeMeta().state;
    if (state === DriverState.Connecting || state === DriverState.Reconnecting) {
      return 'warn';
    }
    if (state === DriverState.Error || state === DriverState.Closed) {
      return 'danger';
    }
    return 'info';
  }

  // Overflow menu item — shown in the dropdown when ▼ is clicked.
  @Builder
  private buildOverflowItem(tab: TabMeta) {
    Row({ space: 8 }) {
      // Status dot
      Circle({ width: 6, height: 6 })
        .fill(this.dotColor(tab.state))
      // Title — truncated with ellipsis
      Text(tab.title)
        .fontSize(13)
        .fontFamily(this.uiFontFamily)
        .fontColor(tab.id === this.activeId ? this.uiTheme.accent : this.uiTheme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      // Close button
      Text('✕')
        .fontSize(10)
        // The chip-✕ hover state (hoverCloseId) moved into TabStrip; the
        // dropdown's backdrop blocks chip hovers while open, so this is
        // always the resting color.
        .fontColor(this.uiTheme.textDim)
        .focusable(false)
        .onClick(() => {
          this.closeTab(tab.id);
          this.showOverflow = false;
        })
    }
    .width('100%')
    .height(32)
    .padding({ left: 10, right: 8 })
    .borderRadius(5)
    .backgroundColor(tab.id === this.activeId ? this.uiTheme.hoverOverlay : Color.Transparent)
    .focusable(false)
    .onClick(() => {
      this.switchTab(tab.id);
      this.scrollToTab(tab.id);
      this.showOverflow = false;
    })
  }

  // Rename sheet — bindSheet(CENTER) native animation, matching settings panel style.
  @Builder
  private buildRenameSheet() {
    Column({ space: 14 }) {
      Text('重命名标签页')
        .fontSize(17)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textPrimary)
        .fontWeight(FontWeight.Medium)
        .width('100%')
      TextInput({ text: $$this.renameText, placeholder: '输入标签页名称' })
        .fontSize(14)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textPrimary)
        .placeholderColor(this.uiTheme.textDim)
        .backgroundColor(this.uiTheme.bgInput)
        .borderRadius(7)
        .border({ width: 1, color: this.uiTheme.accent })
        .height(42)
        .width('100%')
        .defaultFocus(true)
      // Buttons
      Row({ space: 10 }) {
        Row() {
          Text('取消')
            .fontSize(13)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.uiTheme.textPrimary)
        }
        .height(38)
        .layoutWeight(1)
        .borderRadius(7)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.uiTheme.border)
        .focusable(false)
        .onClick(() => { this.closeRenameDialog(); })
        Row() {
          Text('确认')
            .fontSize(13)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.uiTheme.bgBase)
        }
        .height(38)
        .layoutWeight(1)
        .borderRadius(7)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.uiTheme.accent)
        .focusable(false)
        .onClick(() => { this.applyRename(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
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
      token: this.token,
      onTokenChange: (newToken: string) => {
        this.token = newToken;
        if (this.store) {
          const profile: ConnectionProfile = {
            host: this.host.trim(),
            port: this.port.trim(),
            tls: this.tls,
            rememberToken: this.rememberToken,
            token: newToken
          };
          this.store.save(profile);
        }
        this.showSettings = false;
        this.openTab();
      },
      themeName: this.themeName,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink,
      scrollbackLines: this.scrollbackLines,
      uiFontFamily: this.uiFontFamily,
      termFontFamily: this.termFontFamily,
      fontScaleBoost: this.fontScaleBoost,
      cjkVerticalOffset: this.cjkVerticalOffset,
      characterSpacing: this.characterSpacing,
      tabCompact: this.tabCompact,
      onTabCompactChange: (v: boolean) => { this.tabCompact = v; },
      notifyEnabled: this.notifyPrefs.enabled,
      notifyCompleted: this.notifyPrefs.taskCompleted,
      notifyAwaiting: this.notifyPrefs.taskAwaitingInput,
      notifyBackgroundOnly: this.notifyPrefs.onlyWhenBackground,
      notifyBell: this.notifyPrefs.bellEnabled,
      onNotifyEnabledChange: (v: boolean) => {
        this.notifyPrefs.enabled = v;
        this.notifyService.updatePrefs(this.notifyPrefs);
        if (this.store) {
          this.store.saveNotificationPrefs(this.notifyPrefs);
        }
      },
      onNotifyCompletedChange: (v: boolean) => {
        this.notifyPrefs.taskCompleted = v;
        this.notifyService.updatePrefs(this.notifyPrefs);
        if (this.store) {
          this.store.saveNotificationPrefs(this.notifyPrefs);
        }
      },
      onNotifyAwaitingChange: (v: boolean) => {
        this.notifyPrefs.taskAwaitingInput = v;
        this.notifyService.updatePrefs(this.notifyPrefs);
        if (this.store) {
          this.store.saveNotificationPrefs(this.notifyPrefs);
        }
      },
      onNotifyBackgroundOnlyChange: (v: boolean) => {
        this.notifyPrefs.onlyWhenBackground = v;
        this.notifyService.updatePrefs(this.notifyPrefs);
        if (this.store) {
          this.store.saveNotificationPrefs(this.notifyPrefs);
        }
      },
      onNotifyBellChange: (v: boolean) => {
        this.notifyPrefs.bellEnabled = v;
        this.detector.bellEnabled = v;
        if (this.store) {
          this.store.saveNotificationPrefs(this.notifyPrefs);
        }
      },
      onTestNotification: (slotType: number, contentType: number, title: string, text: string) => {
        this.notifyService.publishTest({ slotType, contentType, title, text });
      },
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
