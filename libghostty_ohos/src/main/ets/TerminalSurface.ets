import { common } from '@kit.AbilityKit';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { display } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { TerminalController } from './TerminalController';
import { DEFAULT_TERMINAL_CONFIG, TerminalConfig, TerminalLinkListener, TerminalSearchStatus } from './TerminalTypes';

@Component
export struct TerminalSurface {
  controller: TerminalController = new TerminalController();
  surfaceId: string = 'terminalSurface';
  searchInputId: string = 'terminalSearchInput';
  surfaceColor: string = '#0B0D10';
  onLinkActivated: TerminalLinkListener | null = null;
  // App-level context-menu actions (wired by the host page).
  onOpenSettings: (() => void) | null = null;
  onOpenConnections: (() => void) | null = null;
  onOpenShortcuts: (() => void) | null = null;
  // Whether this surface belongs to the currently active tab. Only the active
  // surface reacts to the page-level search signal.
  @Prop @Watch('onIsActiveTabChange') isActiveTab: boolean = true;
  // Monotonically increasing counter bumped by the host page (e.g. on Ctrl+Shift+F)
  // to request the find overlay on the active terminal.
  @Prop @Watch('onSearchSignal') searchSignal: number = 0;

  private context: common.UIAbilityContext | null = null;
  private searchInputController: TextInputController = new TextInputController();
  private fallbackTimer: number = -1;
  // Dirty-gated present poll. The native renderer composites a SURFACE buffer
  // that this device will not present on its own (no independent vsync). Each
  // tick asks the controller whether a new frame was produced; only then do we
  // bump presentTick to force one ArkUI frame, which makes the compositor latch
  // the buffer. When idle nothing is bumped, so no frames/vsync are requested.
  private presentTimer: number = -1;
  private contextMenuSelectedText: string = '';
  private contextMenuScreenContent: string = '';
  private contextMenuCanPaste: boolean = false;

  // Bumped by the present poll when the native side has a new frame. Bound to an
  // invisible sibling element (NOT the XComponent) so re-rendering it submits an
  // ArkUI frame that re-latches the surface, without pushing the surface into an
  // opacity/offscreen cache.
  @State private presentTick: number = 0;
  @State private appliedFontSize: number = DEFAULT_TERMINAL_CONFIG.fontSize;
  @State private useTextFallback: boolean = false;
  @State private fallbackContent: string = '';
  @State private fallbackError: string = '';
  @State private searchVisible: boolean = false;
  @State private searchText: string = '';
  @State private searchTotal: number = 0;
  @State private searchSelected: number = -1;
  // Hover states for search bar buttons
  @State private hoverSearchPrev: boolean = false;
  @State private hoverSearchNext: boolean = false;
  @State private hoverSearchClose: boolean = false;
  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // Pre-request READ_PASTEBOARD so the permission dialog (if any) appears
    // once at startup rather than silently blocking the first paste attempt.
    // On API 12 getData/getDataSync require this permission to be granted;
    // without it the call silently returns empty data.
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(
        this.context, ['ohos.permission.READ_PASTEBOARD']
      ).catch(() => {});
    } catch (_) {}
    this.controller.setConfigListener((config: TerminalConfig) => {
      this.appliedFontSize = config.fontSize;
    });
    this.controller.setLinkListener((url: string) => {
      this.handleLinkActivated(url);
    });
    this.controller.setCopyRequestListener(() => {
      const text = this.controller.getSelectedText();
      if (text.length > 0) {
        this.copyToClipboard(text);
      }
    });
    this.controller.setPasteRequestListener(() => {
      this.pasteFromClipboard();
    });
    this.appliedFontSize = this.controller.getConfig().fontSize;
  }

  aboutToDisappear(): void {
    this.stopFallbackPolling();
    this.stopPresentPolling();
    this.controller.setConfigListener(null);
    this.controller.setLinkListener(null);
    this.controller.setCopyRequestListener(null);
    this.controller.setPasteRequestListener(null);
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      this.buildTerminalXComponent();
      if (this.useTextFallback) {
        this.buildTextFallback();
      }
      if (this.searchVisible) {
        this.buildSearchOverlay();
      }
    }
    .width('100%')
    .height('100%')
    .padding(0)
    .backgroundColor(this.surfaceColor)
  }

  @Builder
  private buildTerminalXComponent() {
    XComponent({
      id: this.surfaceId,
      // SURFACE mode: on this device the XComponent surface is composited as part
      // of the ArkUI window tree (not an independent RS hardware layer). Whenever
      // ArkUI commits a new frame, RS composites all pending surface buffers —
      // including ours. So we just need to force an ArkUI frame after each native
      // render, which is what the presentTick + offset trick does. TEXTURE mode
      // doesn't work because re-triggering an ArkUI frame doesn't automatically
      // re-acquire the GPU texture from the BufferQueue (that requires a
      // FrameAvailable notification that this device doesn't deliver reliably).
      type: XComponentType.SURFACE,
      libraryname: 'libghostty_ohos'
    })
      .onLoad((nativeContext?: Object) => {
        if (!nativeContext || !this.context) {
          return;
        }

        this.controller.bindNative(nativeContext, this.context, this.getDisplayDensity());
        this.useTextFallback = !this.controller.isRendererReady();
        this.fallbackError = this.controller.getRendererError();
        this.appliedFontSize = this.controller.getConfig().fontSize;
        if (this.useTextFallback) {
          this.syncFallbackScreen();
          this.startFallbackPolling();
        } else {
          this.stopFallbackPolling();
          this.startPresentPolling();
        }
      })
      .onDestroy(() => {
        this.stopFallbackPolling();
        this.stopPresentPolling();
        this.controller.unbindNative();
      })
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const density = this.getDisplayDensity();
        const globalX = Number(newValue.globalPosition?.x ?? 0);
        const globalY = Number(newValue.globalPosition?.y ?? 0);
        const width = Number(newValue.width ?? 0);
        const height = Number(newValue.height ?? 0);
        if (Number.isFinite(globalX) && Number.isFinite(globalY) &&
          Number.isFinite(width) && Number.isFinite(height)) {
          this.controller.setSurfaceFrame(
            globalX * density,
            globalY * density,
            width * density,
            height * density
          );
        }
      })
      .onTouch((_event?: TouchEvent) => {
        if (this.searchVisible) {
          this.searchInputController.stopEditing();
        }
        // Give focus to the XComponent so native key events (arrow keys, control
        // sequences, function keys) are handled by the ghostty engine directly.
        // Soft-keyboard / CJK input is driven natively: the native layer attaches
        // the system IME (OH_InputMethodController) and raises it on tap, so a
        // single XComponent owns keyboard, IME, scrolling, selection and paste.
        this.requestTerminalFocus();
      })
      .focusable(true)
      .focusOnTouch(true)
      .defaultFocus(true)
      // Remove this component from the Tab-key focus ring so that pressing Tab
      // inside the terminal (autocomplete, Shift-Tab in TUI apps) does not
      // cause ArkUI to move focus away to the next focusable widget and stop
      // delivering subsequent keystrokes to the native engine.
      .tabIndex(-1)
      .width('100%')
      .height('100%')
      .backgroundColor(this.surfaceColor)
      // Present driver. Every imperceptible trick (sibling text, bg colour,
      // sub-pixel translate) was culled by ArkUI as "no visible change" and never
      // dirtied this node, so the TEXTURE was never re-sampled. A 1px layout
      // offset cannot be culled: it forces ArkUI to re-lay-out and recomposite
      // this node, re-sampling the latest native buffer. Toggled only when native
      // produced a frame (presentTick), so an idle terminal does not jitter.
      .offset({ x: 0, y: this.presentTick % 2 === 0 ? 0 : 1 })
      .bindContextMenu(this.buildTerminalContextMenu(), ResponseType.RightClick)
  }

  @Builder
  private buildTextFallback() {
    Scroll() {
      Text(this.fallbackContent.length > 0 ? this.fallbackContent : this.fallbackError)
        .width('100%')
        .textAlign(TextAlign.Start)
        .fontSize(this.appliedFontSize)
        .fontFamily('monospace')
        .fontColor('#D8DEE9')
        .lineHeight(this.appliedFontSize * 1.35)
        .padding(12)
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .width('100%')
    .height('100%')
    .backgroundColor(this.surfaceColor)
  }

  @Builder
  private buildSearchOverlay() {
    Column() {
      Row({ space: 0 }) {
        // Search input
        TextInput({ text: this.searchText, controller: this.searchInputController })
          .id(this.searchInputId)
          .width(200)
          .height(34)
          .fontSize(13)
          .fontColor('#F4F7FB')
          .placeholderColor('#8A94A6')
          .backgroundColor('#0E1318')
          .caretColor('#3DD6C4')
          .borderRadius({ topLeft: 7, topRight: 0, bottomLeft: 7, bottomRight: 0 })
          .padding({ left: 10, right: 10 })
          .onChange((value: string) => {
            this.searchText = value;
            this.controller.updateSearch(value);
            this.syncSearchStatus();
          })
          .onSubmit(() => { this.navigateSearch(true); })

        // Divider
        Row()
          .width(1)
          .height(34)
          .backgroundColor('#1E2630')

        // Match count
        Text(this.searchLabel())
          .fontSize(12)
          .fontColor(this.searchTotal > 0 ? '#3DD6C4' : '#8A94A6')
          .width(48)
          .height(34)
          .textAlign(TextAlign.Center)
          .backgroundColor('#11161D')

        // Divider
        Row()
          .width(1)
          .height(34)
          .backgroundColor('#1E2630')

        // Prev ↑
        Row() {
          Text('↑')
            .fontSize(15)
            .fontColor(this.hoverSearchPrev ? '#F4F7FB' : '#8A94A6')
            .animation({ duration: 100, curve: Curve.EaseOut })
        }
        .width(34)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.hoverSearchPrev ? '#1FFFFFFF' : '#11161D')
        .animation({ duration: 100, curve: Curve.EaseOut })
        .onHover((h: boolean) => { this.hoverSearchPrev = h; })
        .onClick(() => { this.navigateSearch(false); })

        // Divider
        Row()
          .width(1)
          .height(34)
          .backgroundColor('#1E2630')

        // Next ↓
        Row() {
          Text('↓')
            .fontSize(15)
            .fontColor(this.hoverSearchNext ? '#F4F7FB' : '#8A94A6')
            .animation({ duration: 100, curve: Curve.EaseOut })
        }
        .width(34)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.hoverSearchNext ? '#1FFFFFFF' : '#11161D')
        .animation({ duration: 100, curve: Curve.EaseOut })
        .onHover((h: boolean) => { this.hoverSearchNext = h; })
        .onClick(() => { this.navigateSearch(true); })

        // Divider
        Row()
          .width(1)
          .height(34)
          .backgroundColor('#1E2630')

        // Close ✕
        Row() {
          Text('✕')
            .fontSize(13)
            .fontColor(this.hoverSearchClose ? '#FF6B6B' : '#8A94A6')
            .animation({ duration: 100, curve: Curve.EaseOut })
        }
        .width(34)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .borderRadius({ topLeft: 0, topRight: 7, bottomLeft: 0, bottomRight: 7 })
        .backgroundColor(this.hoverSearchClose ? '#17FF6B6B' : '#11161D')
        .animation({ duration: 100, curve: Curve.EaseOut })
        .onHover((h: boolean) => { this.hoverSearchClose = h; })
        .onClick(() => { this.closeSearch(); })
      }
      // Single unified container row: flat pill shape
      .borderRadius(8)
      .border({ width: 1, color: '#1E2630' })
      .clip(true)
      .shadow({ radius: 16, color: '#4D000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.End)
    .padding({ top: 12, right: 12 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  private getDisplayDensity(): number {
    try {
      return display.getDefaultDisplaySync().densityPixels;
    } catch (err) {
      console.error('Failed to get display density: ' + JSON.stringify(err));
      return 1;
    }
  }

  private requestTerminalFocus(): void {
    focusControl.requestFocus(this.surfaceId);
  }

  // Host page bumped searchSignal — open (or refocus) the find overlay, but only
  // on the active tab's surface so background terminals stay untouched.
  private onSearchSignal(): void {
    if (this.searchSignal > 0 && this.isActiveTab) {
      this.openSearch(this.searchVisible ? this.searchText : '');
    }
  }

  private startFallbackPolling(): void {
    if (this.fallbackTimer >= 0) {
      return;
    }

    this.fallbackTimer = setInterval(() => {
      this.syncFallbackScreen();
    }, 100) as number;
  }

  private stopFallbackPolling(): void {
    if (this.fallbackTimer < 0) {
      return;
    }

    clearInterval(this.fallbackTimer);
    this.fallbackTimer = -1;
  }

  private startPresentPolling(): void {
    if (this.presentTimer >= 0) {
      return;
    }
    // ~60fps dirty-gated poll. Only bumps presentTick when native produced a new
    // frame. presentTick drives a 1px offset toggle on the XComponent node (see
    // build), which is the only un-cullable way to dirty the node so ArkUI
    // re-samples the TEXTURE and recomposites. Idle terminal bumps nothing.
    this.presentTimer = setInterval(() => {
      if (this.controller.consumePresentNeeded()) {
        this.presentTick = (this.presentTick + 1) & 0xffff;
      }
    }, 16) as number;
  }

  private stopPresentPolling(): void {
    if (this.presentTimer < 0) {
      return;
    }
    clearInterval(this.presentTimer);
    this.presentTimer = -1;
  }

  private syncFallbackScreen(): void {
    if (!this.controller.isAttached()) {
      return;
    }

    try {
      const content = this.controller.getScreenContent();
      if (content.length > 0) {
        this.fallbackContent = content;
      } else if (this.fallbackError.length > 0) {
        this.fallbackContent = this.fallbackError + '\n\nWaiting for terminal output...';
      }
    } catch (err) {
      this.fallbackContent = 'Failed to read terminal buffer';
      console.error('Failed to sync fallback screen: ' + JSON.stringify(err));
    }
  }

  private handleLinkActivated(url: string): void {
    if (url.length === 0) {
      return;
    }

    if (this.onLinkActivated) {
      this.onLinkActivated(url);
      return;
    }

    if (!this.context) {
      return;
    }

    this.context.openLink(url).catch((err: Object) => {
      console.error('Failed to open terminal link: ' + JSON.stringify(err));
    });
  }

  // Submenu for buffer / selection operations (the "缓冲区 ▸" cascade).
  @Builder
  private buildBufferSubMenu() {
    Menu() {
      if (this.hasTerminalSelection()) {
        MenuItem({ content: '复制选区' })
          .onClick(() => {
            this.copyToClipboard(this.controller.getSelectedText());
          })
      }
      if (this.hasTerminalScreenContent()) {
        MenuItem({ content: '复制屏幕' })
          .onClick(() => {
            this.copyToClipboard(this.controller.getScreenContent());
          })
      }
      if (this.hasTerminalSelection()) {
        MenuItem({ content: '清除选择' })
          .onClick(() => {
            this.controller.clearSelection();
            this.requestTerminalFocus();
          })
      }
    }
  }

  @Builder
  private buildTerminalContextMenu() {
    Menu() {
      MenuItem({ content: '查找' })
        .onClick(() => {
          this.openSearch(this.searchVisible ? this.searchText : '');
        })
      if (this.hasTerminalSelection()) {
        MenuItem({ content: '查找选中' })
          .onClick(() => {
            this.openSearch(this.controller.getSelectedText());
          })
      }
      MenuItem({ content: '粘贴' })
        .enabled(this.hasClipboardContents())
        .onClick(() => {
          this.pasteFromClipboard();
        })
      MenuItem({ content: '缓冲区', builder: this.buildBufferSubMenu })
      MenuItem({ content: '连接管理' })
        .onClick(() => {
          if (this.onOpenConnections) {
            this.onOpenConnections();
          }
        })
      MenuItem({ content: '设置' })
        .onClick(() => {
          if (this.onOpenSettings) {
            this.onOpenSettings();
          }
        })
      MenuItem({ content: '快捷键' })
        .onClick(() => {
          if (this.onOpenShortcuts) {
            this.onOpenShortcuts();
          }
        })
    }
  }

  private hasTerminalSelection(): boolean {
    return this.controller.getSelectedText().length > 0;
  }

  private searchLabel(): string {
    if (this.searchTotal <= 0) {
      return '0/0';
    }
    if (this.searchSelected >= 0) {
      return `${this.searchSelected + 1}/${this.searchTotal}`;
    }
    return `-/${this.searchTotal}`;
  }

  // Host toggles which tab is active. Input (keyboard + IME) is handled
  // entirely by the native layer attached to the focused XComponent, so there
  // is nothing to do here beyond letting ArkUI re-evaluate focus naturally.
  private onIsActiveTabChange(): void {
  }

  private openSearch(initialQuery: string): void {
    const nextQuery = initialQuery.length > 0 ? initialQuery : this.searchText;
    this.searchVisible = true;
    this.searchText = nextQuery;
    this.controller.startSearch(nextQuery);
    this.syncSearchStatus();
    setTimeout(() => {
      focusControl.requestFocus(this.searchInputId);
    }, 0);
  }

  private navigateSearch(next: boolean): void {
    this.controller.navigateSearch(next);
    this.syncSearchStatus();
    setTimeout(() => {
      focusControl.requestFocus(this.searchInputId);
    }, 0);
  }

  private closeSearch(): void {
    this.searchInputController.stopEditing();
    this.controller.endSearch();
    this.searchVisible = false;
    this.searchText = '';
    this.searchTotal = 0;
    this.searchSelected = -1;
    setTimeout(() => {
      this.requestTerminalFocus();
    }, 0);
  }

  private syncSearchStatus(): void {
    const status: TerminalSearchStatus = this.controller.getSearchStatus();
    this.searchVisible = status.active || this.searchVisible;
    this.searchTotal = status.total;
    this.searchSelected = status.selected;
    this.searchText = status.query;
  }

  private hasTerminalScreenContent(): boolean {
    return this.controller.getScreenContent().trim().length > 0;
  }

  private hasClipboardContents(): boolean {
    try {
      return pasteboard.getSystemPasteboard().hasDataSync();
    } catch (err) {
      console.error('Failed to query terminal clipboard state: ' + JSON.stringify(err));
      return false;
    }
  }

  private copyToClipboard(text: string): void {
    if (text.length === 0) {
      return;
    }
    const clipboard = pasteboard.getSystemPasteboard();
    try {
      clipboard.setDataSync(pasteboard.createPlainTextData(text));
    } catch (err) {
      console.error('Failed to copy terminal text: ' + JSON.stringify(err));
    }
    this.requestTerminalFocus();
  }

  private extractClipboardText(data: pasteboard.PasteData): string {
    let text = data.getPrimaryText();
    if (text.length === 0 && data.getRecordCount() > 0) {
      text = data.getRecord(0).toPlainText();
    }
    return text;
  }

  private pasteFromClipboard(): void {
    const clipboard = pasteboard.getSystemPasteboard();
    // Try synchronous path first (works immediately when clipboard is already
    // accessible in the foreground).  If it returns empty — which can happen
    // the very first time because HarmonyOS is showing a brief privacy
    // indicator — fall back to the async path so the next access succeeds.
    try {
      const data = clipboard.getDataSync();
      const text = this.extractClipboardText(data);
      if (text.length > 0) {
        this.controller.write(text);
        this.requestTerminalFocus();
        return;
      }
    } catch (err) {
      console.error('Paste sync failed, retrying async: ' + JSON.stringify(err));
    }
    // Async fallback: the system authorises the access while this resolves.
    clipboard.getData().then((data: pasteboard.PasteData) => {
      const text = this.extractClipboardText(data);
      if (text.length > 0) {
        this.controller.write(text);
      }
      this.requestTerminalFocus();
    }).catch((err: Error) => {
      console.error('Paste async failed: ' + JSON.stringify(err));
      this.requestTerminalFocus();
    });
  }
}
