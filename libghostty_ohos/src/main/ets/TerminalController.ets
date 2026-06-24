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
  drainPendingInput: () => string;
  setInputCallback: (callback: ((data: string) => void) | null) => void;
  drainPendingLinkActivation: () => string;
  drainPendingContextMenuRequest: () => string;
  drainPendingCopyRequest: () => boolean;
  drainPendingPasteRequest: () => boolean;
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
}

type TerminalConfigListener = (config: TerminalConfig, themeName: string) => void;
type TerminalSizeListener = (size: TerminalSize) => void;

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
  private inputPollTimer: number = -1;
  // Invoked right after output is fed (and the native side has drawn+flushed).
  // The host surface uses it to bump an @State so ArkUI runs a frame and
  // composites the XComponent's SURFACE layer. On devices/windows where the
  // XComponent receives no independent vsync, a bare NativeWindow flush is not
  // presented until some unrelated UI event; this synthetic repaint pulse is
  // what makes terminal output (e.g. the echo of a physical-keyboard keystroke)
  // appear immediately instead of one keystroke late.
  private repaintListener: (() => void) | null = null;
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
    this.startInputPolling();
    this.bindWindowMetadata(context);
    this.notifyAttachmentChanged(true);
  }

  unbindNative(): void {
    if (this.native) {
      this.native.setInputCallback(null);
    }
    this.unbindWindowMetadata();
    this.stopInputPolling();
    this.native = null;
    this.notifyAttachmentChanged(false);
  }

  isAttached(): boolean {
    return this.native !== null;
  }

  setConfig(config: TerminalConfig): void {
    this.config = cloneTerminalConfig(config);
    this.applyConfig();
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

    this.setConfig(nextConfig);
  }

  getConfig(): TerminalConfig {
    return cloneTerminalConfig(this.config);
  }

  setTheme(themeName: string): boolean {
    this.themeName = themeName;
    const loaded = this.applyTheme();
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
    if (this.linkListener || this.contextMenuListener) {
      this.startInputPolling();
    } else {
      this.stopInputPolling();
    }
  }

  setLinkListener(listener: TerminalLinkListener | null): void {
    this.linkListener = listener;
    if (this.inputListener || this.linkListener || this.contextMenuListener) {
      this.startInputPolling();
    } else {
      this.stopInputPolling();
    }
  }

  setContextMenuListener(listener: TerminalContextMenuListener | null): void {
    this.contextMenuListener = listener;
    if (this.inputListener || this.linkListener || this.contextMenuListener) {
      this.startInputPolling();
    } else {
      this.stopInputPolling();
    }
  }

  setCopyRequestListener(listener: (() => void) | null): void {
    this.copyRequestListener = listener;
    if (listener) {
      this.startInputPolling();
    }
  }

  setPasteRequestListener(listener: (() => void) | null): void {
    this.pasteRequestListener = listener;
    if (listener) {
      this.startInputPolling();
    }
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
    // The native feedOutput above already drew+flushed the new content. Poke the
    // host surface so ArkUI runs a frame and the compositor presents that buffer
    // now, rather than waiting for the next input event.
    if (this.repaintListener) {
      this.repaintListener();
    }
  }

  setRepaintListener(listener: (() => void) | null): void {
    this.repaintListener = listener;
  }

  resize(cols: number, rows: number): void {
    if (!this.native) {
      return;
    }
    this.native.resizeTerminal(cols, rows);
  }

  setSurfaceOrigin(left: number, top: number): void {
    if (!this.native) {
      return;
    }
    this.native.setSurfaceOrigin(left, top);
  }

  setSurfaceFrame(left: number, top: number, width: number, height: number): void {
    if (!this.native) {
      return;
    }
    this.native.setSurfaceFrame(left, top, width, height);
    this.notifySizeChanged();
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
  }

  navigateSearch(next: boolean): void {
    if (!this.native) {
      return;
    }
    this.native.navigateSearch(next);
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

  private startInputPolling(): void {
    const needsPoll = this.linkListener !== null ||
      this.contextMenuListener !== null ||
      this.copyRequestListener !== null ||
      this.pasteRequestListener !== null;
    if (!this.native || !needsPoll || this.inputPollTimer >= 0) {
      return;
    }

    this.inputPollTimer = setInterval(() => {
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
    }, 16) as number;
  }

  private stopInputPolling(): void {
    if (this.inputPollTimer < 0) {
      return;
    }
    clearInterval(this.inputPollTimer);
    this.inputPollTimer = -1;
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
    if (!this.native || !this.sizeListener) {
      return;
    }
    const size = this.native.getTerminalSize();
    if (size.cols <= 0 || size.rows <= 0) {
      return;
    }
    if (size.cols === this.lastReportedSize.cols && size.rows === this.lastReportedSize.rows) {
      return;
    }
    this.lastReportedSize = { cols: size.cols, rows: size.rows };
    this.sizeListener(this.lastReportedSize);
  }
}
