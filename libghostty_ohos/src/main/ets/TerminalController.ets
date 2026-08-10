import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import {
  TerminalAttachmentListener,
  CellMetrics,
  cloneTerminalConfig,
  CursorPosition,
  DEFAULT_TERMINAL_CONFIG,
  DEFAULT_THEME_NAME,
  TerminalConfig,
  TerminalConfigPatch,
  TerminalContextMenuListener,
  TerminalInputListener,
  TerminalLinkListener,
  TerminalSearchStatus,
  TerminalSize
} from './TerminalTypes';

interface TerminalNativeBridge {
  writeInput: (data: string) => void;
  feedOutput: (data: string) => void;
  feedOutputBytes: (data: ArrayBuffer) => void;
  clearMouseTracking: () => void;
  drainPendingInput: () => string;
  setInputCallback: (callback: ((data: string) => void) | null) => void;
  drainPendingLinkActivation: () => string;
  drainPendingContextMenuRequest: () => string;
  drainPendingCopyRequest: () => boolean;
  drainPendingPasteRequest: () => boolean;
  drainPendingFrame: () => boolean;
  resizeTerminal: (cols: number, rows: number) => void;
  getScreenContent: () => string;
  getCursorPosition: () => CursorPosition;
  getTerminalSize: () => TerminalSize;
  getCellMetrics: () => CellMetrics;
  setFilesDir: (filesDir: string) => void;
  setResourceManager: (resourceManager: Object) => void;
  setWindowInfo: (windowId: number, left: number, top: number) => void;
  setSurfaceOrigin: (left: number, top: number) => void;
  setSurfaceFrame: (left: number, top: number, width: number, height: number) => void;
  scrollView: (delta: number) => void;
  resetScroll: () => void;
  getScrollbackSize: () => number;
  startSelection: (row: number, col: number) => void;
  updateSelection: (row: number, col: number) => void;
  clearSelection: () => void;
  resetTerminal: () => void;
  getSelectedText: () => string;
  startSearch: (query: string) => void;
  searchSelection: () => void;
  updateSearch: (query: string) => void;
  navigateSearch: (next: boolean) => void;
  endSearch: () => void;
  getSearchStatus: () => TerminalSearchStatus;
  setConfig: (config: TerminalConfig) => void;
  setDensity: (density: number) => void;
  loadTheme: (themeName: string) => boolean;
  getThemeList: () => string[];
  getThemeColors: (themeName: string) => string[];
  isRendererReady: () => boolean;
  getRendererError: () => string;
  focusTerminal: () => void;
  getCurrentBgColor: () => number;
}

type TerminalConfigListener = (config: TerminalConfig, themeName: string) => void;
type TerminalSizeListener = (size: TerminalSize) => void;

// Adaptive polling cadence for the native event drains (link activation,
// context menu, copy/paste requests) and the frame-present notification.
// Instead of a fixed 16 ms interval that burns N-API crossings even while the
// terminal is idle, poll fast while there's been recent activity and fall back
// to an idle cadence (150 ms) otherwise. 150 ms still catches every native
// cursor-blink frame (250 ms period), so blinking stays smooth without running
// the fast loop.
//
// POLL_FAST_MS is 8 ms, not 16: the native renderer flushes one buffer per
// OH_NativeVSync (8.3 ms at 120 Hz). A 16 ms poll presents every other buffer,
// capping scroll smoothness at ~60 Hz; 8 ms keeps the presentation loop at the
// display cadence. The tick itself is cheap when there is no fresh buffer (a
// few N-API crossings), so the extra wakeups only matter during activity.
const POLL_FAST_MS: number = 8;
const POLL_IDLE_MS: number = 150;
const POLL_ACTIVE_WINDOW_MS: number = 800;

export class TerminalController {
  private native: TerminalNativeBridge | null = null;
  private config: TerminalConfig = cloneTerminalConfig(DEFAULT_TERMINAL_CONFIG);
  private themeName: string = DEFAULT_THEME_NAME;
  private configListener: TerminalConfigListener | null = null;
  private inputListener: TerminalInputListener | null = null;
  private linkListener: TerminalLinkListener | null = null;
  private contextMenuListener: TerminalContextMenuListener | null = null;
  private attachmentListener: TerminalAttachmentListener | null = null;
  private sizeListener: TerminalSizeListener | null = null;
  private copyRequestListener: (() => void) | null = null;
  private pasteRequestListener: (() => void) | null = null;
  private framePresentListener: (() => void) | null = null;
  // Adaptive poll state (see POLL_* constants above).
  private adaptivePollTimer: number = -1;
  private lastActivityMs: number = 0;
  private pollFast: boolean = false;
  private trackedWindow: window.Window | null = null;
  private windowRectListener: ((options: window.RectChangeOptions) => void) | null = null;
  private lastReportedSize: TerminalSize = { cols: 0, rows: 0 };

  bindNative(native: Object, context: common.UIAbilityContext, density: number): void {
    this.native = native as TerminalNativeBridge;
    this.native.setDensity(density);
    this.native.setFilesDir(context.filesDir);
    this.native.setResourceManager(context.resourceManager);
    this.native.setInputCallback(this.inputListener);
    this.applyTheme();
    this.applyConfig();
    // Treat the bind itself as activity so the theme/config frames drawn during
    // bind are polled at fast cadence (the very first frame must be presented).
    this.bumpActivity();
    this.updatePolling();
    this.bindWindowMetadata(context);
    this.notifyAttachmentChanged(true);
  }

  unbindNative(): void {
    if (this.sizeNotifyTimer >= 0) {
      clearTimeout(this.sizeNotifyTimer);
      this.sizeNotifyTimer = -1;
    }
    if (this.native) {
      this.native.setInputCallback(null);
    }
    this.unbindWindowMetadata();
    this.native = null;
    // Native is gone — the poll (which guards on this.native) stops itself.
    this.updatePolling();
    this.notifyAttachmentChanged(false);
  }

  isAttached(): boolean {
    return this.native !== null;
  }

  setConfig(config: TerminalConfig): void {
    this.config = cloneTerminalConfig(config);
    this.applyConfig();
    this.bumpActivity();
    this.notifyConfigChanged();
    // A font-size change re-flows the grid into a new column/row count on the
    // native side, so re-publish the terminal size to drive a driver.resize()
    // (PTY/WebSocket SIGWINCH). Without this the remote shell keeps the old
    // dimensions and the screen looks misaligned after zooming.
    this.notifySizeChanged();
  }

  updateConfig(patch: TerminalConfigPatch): void {
    const nextConfig = cloneTerminalConfig(this.config);
    if (patch.fontSize !== undefined) {
      nextConfig.fontSize = patch.fontSize;
    }
    if (patch.fontFamily !== undefined) {
      nextConfig.fontFamily = patch.fontFamily;
    }
    if (patch.lineSpacing !== undefined) {
      nextConfig.lineSpacing = patch.lineSpacing;
    }
    if (patch.scrollbackLines !== undefined) {
      nextConfig.scrollbackLines = patch.scrollbackLines;
    }
    if (patch.bgColor !== undefined) {
      nextConfig.bgColor = patch.bgColor;
    }
    if (patch.fgColor !== undefined) {
      nextConfig.fgColor = patch.fgColor;
    }
    if (patch.cursorStyle !== undefined) {
      nextConfig.cursorStyle = patch.cursorStyle;
    }
    if (patch.cursorBlink !== undefined) {
      nextConfig.cursorBlink = patch.cursorBlink;
    }
    if (patch.fontScaleBoost !== undefined) {
      nextConfig.fontScaleBoost = patch.fontScaleBoost;
    }
    if (patch.cjkVerticalOffset !== undefined) {
      nextConfig.cjkVerticalOffset = patch.cjkVerticalOffset;
    }
    if (patch.characterSpacing !== undefined) {
      nextConfig.characterSpacing = patch.characterSpacing;
    }

    this.setConfig(nextConfig);
  }

  getConfig(): TerminalConfig {
    return cloneTerminalConfig(this.config);
  }

  setTheme(themeName: string): boolean {
    this.themeName = themeName;
    const loaded = this.applyTheme();
    this.bumpActivity();
    this.notifyConfigChanged();
    return loaded;
  }

  getThemeName(): string {
    return this.themeName;
  }

  getThemeList(): string[] {
    if (!this.native) {
      return [];
    }
    return this.native.getThemeList();
  }

  // Returns key colors of a theme as #RRGGBB strings without applying it:
  // [background, foreground, cursor, accent1, accent2, accent3]. Empty on failure.
  getThemeColors(themeName: string): string[] {
    if (!this.native) {
      return [];
    }
    return this.native.getThemeColors(themeName);
  }

  setConfigListener(listener: TerminalConfigListener | null): void {
    this.configListener = listener;
    this.notifyConfigChanged();
  }

  setInputListener(listener: TerminalInputListener | null): void {
    this.inputListener = listener;
    if (this.native) {
      this.native.setInputCallback(this.inputListener);
    }
    this.updatePolling();
  }

  setLinkListener(listener: TerminalLinkListener | null): void {
    this.linkListener = listener;
    this.updatePolling();
  }

  setContextMenuListener(listener: TerminalContextMenuListener | null): void {
    this.contextMenuListener = listener;
    this.updatePolling();
  }

  setCopyRequestListener(listener: (() => void) | null): void {
    this.copyRequestListener = listener;
    this.updatePolling();
  }

  setPasteRequestListener(listener: (() => void) | null): void {
    this.pasteRequestListener = listener;
    this.updatePolling();
  }

  setAttachmentListener(listener: TerminalAttachmentListener | null): void {
    this.attachmentListener = listener;
    this.notifyAttachmentChanged(this.isAttached());
  }

  setSizeListener(listener: TerminalSizeListener | null): void {
    this.sizeListener = listener;
    if (listener) {
      this.notifySizeChanged();
    }
  }

  write(data: string): void {
    if (!this.native || data.length === 0) {
      return;
    }
    this.native.writeInput(data);
  }

  feed(data: string): void {
    if (!this.native || data.length === 0) {
      return;
    }
    this.native.feedOutput(data);
    this.bumpActivity();
  }

  // Byte-oriented feed for bulk output (server ring-buffer replay). Raw frame
  // bytes go straight to the native VT parser — no decodeToString / UTF-16
  // round-trip on the UI thread. The parser is a streaming state machine, so
  // partial escape sequences and UTF-8 characters at chunk boundaries resume
  // safely on the next call.
  feedBytes(data: ArrayBuffer): void {
    if (!this.native || data.byteLength === 0) {
      return;
    }
    this.native.feedOutputBytes(data);
    this.bumpActivity();
  }

  // Clear mouse tracking modes (DEC private 1000/1002/1003/1006) directly
  // through the ghostty mode API.  Unlike feeding CSI sequences through
  // vt_write (feed), this guarantees the composited MOUSE_TRACKING flag
  // queried by reportMouse / wheelScroll is also reset.
  clearMouseTracking(): void {
    if (!this.native) {
      return;
    }
    this.native.clearMouseTracking();
  }

  resize(cols: number, rows: number): void {
    if (!this.native) {
      return;
    }
    this.native.resizeTerminal(cols, rows);
    this.bumpActivity();
  }

  setSurfaceOrigin(left: number, top: number): void {
    if (!this.native) {
      return;
    }
    this.native.setSurfaceOrigin(left, top);
  }

  // Update the native surface frame dimensions immediately (for responsive
  // visual resize) without triggering a size-change notification to the driver.
  // Used on the first onAreaChange event of a resize burst so the native
  // renderer can start adapting while we wait for the resize to settle before
  // sending SIGWINCH to the remote shell.
  setSurfaceFrameImmediate(left: number, top: number, width: number, height: number): void {
    if (!this.native) {
      return;
    }
    this.native.setSurfaceFrame(left, top, width, height);
    this.bumpActivity();
  }

  // Update native surface frame AND schedule a debounced size-change
  // notification. Called from the trailing edge of a resize burst so the driver
  // receives exactly one SIGWINCH at the final size.
  setSurfaceFrame(left: number, top: number, width: number, height: number): void {
    if (!this.native) {
      return;
    }
    this.native.setSurfaceFrame(left, top, width, height);
    this.bumpActivity();
    // Defer size-change notification so the native side has time to process the
    // queued resize in OnFrameTick. Without this, getTerminalSize() returns the
    // old grid dimensions and the listener never fires on the first event of a
    // resize burst — it only fires on a later event, lagging behind the actual
    // size change. We also debounce with a longer settle window so the remote
    // shell receives a single SIGWINCH at the end of the resize, not a storm.
    this.scheduleSizeNotify();
  }

  // Debounced size-change notification. Called after every surface frame update;
  // coalesces rapid resize events so the driver only gets the final terminal
  // size after the window stops changing.
  private sizeNotifyTimer: number = -1;
  private scheduleSizeNotify(): void {
    // Fire after ~one frame (16 ms) so OnFrameTick has time to process the
    // queued native resize. If the grid size hasn't changed yet (OnFrameTick
    // hasn't run), we retry once after another frame. The tight timing keeps
    // the local grid reflow and the remote SIGWINCH nearly simultaneous so
    // the user perceives a single visual update instead of two flashes.
    if (this.sizeNotifyTimer >= 0) {
      clearTimeout(this.sizeNotifyTimer);
    }
    this.sizeNotifyTimer = setTimeout(() => {
      this.sizeNotifyTimer = -1;
      if (!this.tryNotifySize()) {
        // Retry once: OnFrameTick may not have processed the queued resize yet.
        this.sizeNotifyTimer = setTimeout(() => {
          this.sizeNotifyTimer = -1;
          this.tryNotifySize();
        }, 16) as number;
      }
    }, 16) as number;
  }

  // Returns true if the size actually changed and was notified.
  private tryNotifySize(): boolean {
    if (!this.native || !this.sizeListener) {
      return false;
    }
    const size = this.native.getTerminalSize();
    if (size.cols <= 0 || size.rows <= 0) {
      return false;
    }
    if (size.cols === this.lastReportedSize.cols && size.rows === this.lastReportedSize.rows) {
      return false;
    }
    this.lastReportedSize = { cols: size.cols, rows: size.rows };
    this.sizeListener(this.lastReportedSize);
    return true;
  }

  scrollView(delta: number): void {
    if (!this.native) {
      return;
    }
    this.native.scrollView(delta);
  }

  resetScroll(): void {
    if (!this.native) {
      return;
    }
    this.native.resetScroll();
  }

  getScrollbackSize(): number {
    if (!this.native) {
      return 0;
    }
    return this.native.getScrollbackSize();
  }

  getScreenContent(): string {
    if (!this.native) {
      return '';
    }
    return this.native.getScreenContent();
  }

  getCursorPosition(): CursorPosition {
    if (!this.native) {
      return { row: 0, col: 0 };
    }
    return this.native.getCursorPosition();
  }

  getTerminalSize(): TerminalSize {
    if (!this.native) {
      const emptySize: TerminalSize = { cols: 0, rows: 0 };
      return emptySize;
    }
    return this.native.getTerminalSize();
  }

  getCellMetrics(): CellMetrics {
    if (!this.native) {
      return {
        width: Math.max(1, this.config.fontSize * 0.6),
        height: Math.max(1, this.config.fontSize * 1.2)
      };
    }
    return this.native.getCellMetrics();
  }

  startSelection(row: number, col: number): void {
    if (!this.native) {
      return;
    }
    this.native.startSelection(row, col);
  }

  updateSelection(row: number, col: number): void {
    if (!this.native) {
      return;
    }
    this.native.updateSelection(row, col);
  }

  clearSelection(): void {
    if (!this.native) {
      return;
    }
    this.native.clearSelection();
  }

  // Full reset of the emulator (RIS). Call when (re)connecting to a fresh
  // server session so modes left enabled by the previous session (mouse
  // tracking, alt screen, …) don't leak into the new shell.
  resetTerminal(): void {
    if (!this.native) {
      return;
    }
    this.native.resetTerminal();
    this.bumpActivity();
  }

  getSelectedText(): string {
    if (!this.native) {
      return '';
    }
    return this.native.getSelectedText();
  }

  startSearch(query: string = ''): void {
    if (!this.native) {
      return;
    }
    this.native.startSearch(query);
    this.bumpActivity();
  }

  searchSelection(): void {
    if (!this.native) {
      return;
    }
    this.native.searchSelection();
  }

  updateSearch(query: string): void {
    if (!this.native) {
      return;
    }
    this.native.updateSearch(query);
    this.bumpActivity();
  }

  navigateSearch(next: boolean): void {
    if (!this.native) {
      return;
    }
    this.native.navigateSearch(next);
    this.bumpActivity();
  }

  endSearch(): void {
    if (!this.native) {
      return;
    }
    this.native.endSearch();
  }

  getSearchStatus(): TerminalSearchStatus {
    if (!this.native) {
      return {
        active: false,
        total: 0,
        selected: -1,
        query: ''
      };
    }
    return this.native.getSearchStatus();
  }

  // True if the native renderer flushed a new buffer since the last call.
  // The caller must then force an ArkUI window frame (e.g. bump a @State) so
  // RenderService recomposites and presents the freshly flushed buffer — an
  // independent NativeVSync flush alone is not presented while ArkUI is idle.
  drainPendingFrame(): boolean {
    if (!this.native) {
      return false;
    }
    return this.native.drainPendingFrame();
  }

  isRendererReady(): boolean {
    if (!this.native) {
      return false;
    }
    return this.native.isRendererReady();
  }

  getRendererError(): string {
    if (!this.native) {
      return '';
    }
    return this.native.getRendererError();
  }

  // Focus this terminal like a tap: take over the process-wide IME attachment
  // and raise the keyboard. Needed on tab switch / return-to-foreground because
  // ArkUI focus alone does not move IME (soft-keyboard / CJK) input routing.
  focusTerminal(): void {
    if (!this.native) {
      console.info('FT_DIAG focusTerminal: native is null, skipping');
      return;
    }
    console.info('FT_DIAG focusTerminal: calling native.focusTerminal()');
    try {
      this.native.focusTerminal();
    } catch (e) {
      console.error('FT_DIAG focusTerminal: native call failed: ' + JSON.stringify(e));
    }
  }

  // Returns the current live background color (ARGB) from the renderer.
  // Reflects OSC color changes, unlike getThemeColors() which only returns
  // the theme definition. Falls back to 0xFF0B0D10 (Palette.base) on error.
  getCurrentBgColor(): number {
    if (!this.native) {
      return 0xFF0B0D10;
    }
    try {
      return this.native.getCurrentBgColor();
    } catch (e) {
      console.error('FT_DIAG getCurrentBgColor failed: ' + JSON.stringify(e));
      return 0xFF0B0D10;
    }
  }

  private applyConfig(): void {
    if (!this.native) {
      return;
    }
    this.native.setConfig(this.config);
  }

  private applyTheme(): boolean {
    if (!this.native) {
      return false;
    }
    return this.native.loadTheme(this.themeName);
  }

  private notifyConfigChanged(): void {
    if (!this.configListener) {
      return;
    }
    this.configListener(this.getConfig(), this.themeName);
  }

  setFramePresentListener(listener: (() => void) | null): void {
    this.framePresentListener = listener;
    this.updatePolling();
  }

  // Mark that the terminal just produced/consumed activity (output fed, config
  // or theme changed, surface resized, search navigated, user gesture on the
  // surface). Keeps the adaptive poll in fast mode; if the poll was waiting out
  // an idle tick, jump straight to fast so freshly flushed frames present
  // without the idle-cadence latency.
  bumpActivity(): void {
    const now: number = Date.now();
    this.lastActivityMs = now;
    if (this.adaptivePollTimer >= 0 && !this.pollFast) {
      clearTimeout(this.adaptivePollTimer);
      this.adaptivePollTimer = -1;
      this.schedulePoll();
    }
  }

  // True when the terminal has been silent for `windowMs`. The page uses this
  // to skip its live-background poll while idle — a bg change can only arrive
  // inside terminal output (OSC 11), so no output means no change to catch.
  isIdleSince(windowMs: number): boolean {
    return Date.now() - this.lastActivityMs > windowMs;
  }

  // Adaptive polling core. One self-rescheduling timer drains the native event
  // queues (link activation / context menu / copy / paste) AND the frame-present
  // flag. Fast (8 ms, display-cadence) while active, idle (150 ms) otherwise.
  private shouldRunPoll(): boolean {
    return this.linkListener !== null ||
      this.contextMenuListener !== null ||
      this.copyRequestListener !== null ||
      this.pasteRequestListener !== null ||
      this.framePresentListener !== null;
  }

  private updatePolling(): void {
    if (!this.shouldRunPoll() || !this.native) {
      this.stopPolling();
      return;
    }
    this.schedulePoll();
  }

  private schedulePoll(): void {
    if (this.adaptivePollTimer >= 0 || !this.native || !this.shouldRunPoll()) {
      return;
    }
    const fast: boolean = Date.now() - this.lastActivityMs < POLL_ACTIVE_WINDOW_MS;
    if (fast !== this.pollFast) {
      this.pollFast = fast;
    }
    const delay: number = fast ? POLL_FAST_MS : POLL_IDLE_MS;
    this.adaptivePollTimer = setTimeout((): void => {
      this.adaptivePollTimer = -1;
      this.pollTick();
    }, delay) as number;
  }

  private stopPolling(): void {
    if (this.adaptivePollTimer >= 0) {
      clearTimeout(this.adaptivePollTimer);
      this.adaptivePollTimer = -1;
    }
  }

  private pollTick(): void {
    if (!this.native) {
      return;
    }

    const activatedLink = this.linkListener ? this.native.drainPendingLinkActivation() : '';
    if (this.linkListener && activatedLink.length > 0) {
      this.linkListener(activatedLink);
    }

    const pendingContextMenu = this.contextMenuListener ? this.native.drainPendingContextMenuRequest() : '';
    if (this.contextMenuListener && pendingContextMenu.length > 0) {
      const parts = pendingContextMenu.split(',');
      const x = parts.length > 0 ? Number(parts[0]) : 0;
      const y = parts.length > 1 ? Number(parts[1]) : 0;
      this.contextMenuListener(
        Number.isFinite(x) ? x : 0,
        Number.isFinite(y) ? y : 0
      );
    }

    if (this.copyRequestListener && this.native.drainPendingCopyRequest()) {
      this.copyRequestListener();
    }

    if (this.pasteRequestListener && this.native.drainPendingPasteRequest()) {
      this.pasteRequestListener();
    }

    // Frame-present: notify the surface so it dirties the XComponent node and
    // ArkUI re-samples the freshly flushed native buffer.
    if (this.framePresentListener && this.native.drainPendingFrame()) {
      this.framePresentListener();
    }

    this.schedulePoll();
  }

  private bindWindowMetadata(context: common.UIAbilityContext): void {
    this.unbindWindowMetadata();
    const boundNative = this.native;
    if (!boundNative) {
      return;
    }

    void window.getLastWindow(context).then((appWindow: window.Window) => {
      if (this.native !== boundNative) {
        return;
      }

      this.trackedWindow = appWindow;
      this.syncWindowMetadata(appWindow);

      this.windowRectListener = (_options: window.RectChangeOptions) => {
        this.syncWindowMetadata(appWindow);
      };

      try {
        appWindow.on('windowRectChange', this.windowRectListener);
      } catch (err) {
        console.error('Failed to subscribe to windowRectChange: ' + JSON.stringify(err));
      }
    }).catch((err: Object) => {
      console.error('Failed to bind window metadata: ' + JSON.stringify(err));
    });
  }

  private unbindWindowMetadata(): void {
    if (!this.trackedWindow) {
      this.windowRectListener = null;
      return;
    }

    if (this.windowRectListener) {
      try {
        this.trackedWindow.off('windowRectChange', this.windowRectListener);
      } catch (err) {
        console.error('Failed to unsubscribe from windowRectChange: ' + JSON.stringify(err));
      }
    }

    this.trackedWindow = null;
    this.windowRectListener = null;
  }

  private syncWindowMetadata(appWindow: window.Window): void {
    if (!this.native) {
      return;
    }

    try {
      const props = appWindow.getWindowProperties();
      try {
        const globalRect = appWindow.getGlobalRect();
        this.native.setWindowInfo(props.id, globalRect.left, globalRect.top);
      } catch (_err) {
        this.native.setWindowInfo(props.id, props.windowRect.left, props.windowRect.top);
      }
    } catch (err) {
      console.error('Failed to sync window metadata: ' + JSON.stringify(err));
    }
  }

  private notifyAttachmentChanged(attached: boolean): void {
    if (!this.attachmentListener) {
      return;
    }
    this.attachmentListener(attached);
  }

  private notifySizeChanged(): void {
    this.tryNotifySize();
  }
}
