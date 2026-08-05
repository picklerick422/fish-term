import { UiTheme, REFINED_DARK_THEME, RADIUS_CONTROL, RADIUS_PILL } from '../theme/UiTheme';
import { DriverState } from '../transport/TerminalDriver';
import { DEFAULT_FONT_SIZE, DEFAULT_UI_FONT } from '../theme/FontScale';

// Reactive per-tab metadata that drives the tab strip. The heavy controller /
// session live in TerminalRuntime, keyed by id in `runtimes` on the page.
// Must be @Observed class — TabChip observes it via @ObjectLink, so in-place
// title/status edits re-render the chip without rebuilding it (the stable
// ForEach key keeps an open right-click context menu alive across title
// changes). The page still reassigns `tabs` so its own getters (StatusBanner,
// status capsule, overflow list) re-evaluate.
@Observed
export class TabMeta {
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

// Top strip that replaces the system title bar: app logo + tabs + "+" + settings.
// Extracted from pages/Index.ets (Task 2) — behavior preserved; every control
// stays .focusable(false) so the active terminal XComponent keeps keyboard focus.
//
// The tab-overflow dropdown itself stays in Index (absolute positioning against
// the root Stack); the ▼ button here just reports onOpenOverflow().
//
// statusText / showStatusCapsule drive the Task 6 status capsule rendered
// left of the settings icon (success tokens; only when showStatusCapsule).
// statusColor is accepted for interface stability but not rendered here.
@Component
export struct TabStrip {
  // @Link (not @Prop): @Prop deep-copies the array AND its TabMeta elements, so
  // the chips' @ObjectLink would observe copies — never the instances the page
  // mutates in place via updateTabTitle/updateTabMeta. @Link shares the real
  // instances, so in-place @Observed field edits reach TabChip directly and the
  // chip re-renders without being rebuilt (stable ForEach key keeps an open
  // context menu alive). TabStrip never mutates the array itself — reordering
  // goes through onReorder back to the page.
  @Link tabs: TabMeta[];
  @Prop activeId: number = -1;
  @Prop themeBg: string = REFINED_DARK_THEME.bgBase;
  @Prop themeFg: string = REFINED_DARK_THEME.textPrimary;
  @Prop tabCompact: boolean = false;
  @Prop fontSize: number = DEFAULT_FONT_SIZE;
  @Prop uiFontFamily: string = DEFAULT_UI_FONT;
  @Prop statusText: string = '';
  @Prop statusColor: string = '';
  @Prop showStatusCapsule: boolean = false;
  // Imperative handles shared with the page BY REFERENCE (plain members, same
  // pattern as TerminalSurface.controller) so Index's scrollToTab / mouse-wheel
  // handler and the chip measurement writes below all hit the same instances.
  tabScroller: Scroller = new Scroller();
  chipWidths: Map<number, number> = new Map<number, number>();

  onSwitchTab: (id: number) => void = (_id: number) => {};
  onCloseTab: (id: number) => void = (_id: number) => {};
  onNewTab: () => void = () => {};
  onReorder: (from: number, to: number) => void = (_from: number, _to: number) => {};
  onRenameTab: (id: number) => void = (_id: number) => {};
  onCloseOthers: (id: number) => void = (_id: number) => {};
  onOpenGuide: () => void = () => {};
  onOpenSettings: () => void = () => {};
  onOpenAbout: () => void = () => {};
  onOpenOverflow: () => void = () => {};
  onToggleSidebar: () => void = () => {};
  @Prop sidebarVisible: boolean = true;

  @State private hoverAddTab: boolean = false;
  @State private hoverSettings: boolean = false;
  @State private hoverLogo: boolean = false;
  @State private hoverSidebarToggle: boolean = false;
  @State private hoverGuide: boolean = false;
  @State private hoverOverflow: boolean = false;
  // Tab drag-reorder via horizontal PanGesture (live reorder, stays on baseline).
  // Per-chip hover / drag bookkeeping (hoverClose, hoverSelf, didDrag,
  // lastDragEnd) lives inside TabChip.
  @State private dragTabId: number = -1;
  @State private dragOffsetX: number = 0;
  @State private dragSwaps: number = 0;
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;
  private dragUnit: number = 110;
  // Pending index of the dragged chip during a live reorder. The tabs array is
  // owned (and spliced) by the page via onReorder; this tracks where the chip
  // sits so rapid successive moves within one gesture event stay consistent
  // before the updated tabs prop syncs back down.
  private dragCurIdx: number = -1;

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
  // The splice itself happens on the page (it owns the tabs array).
  private moveDragged(dir: number): boolean {
    if (this.dragCurIdx < 0) {
      return false;
    }
    const target: number = this.dragCurIdx + dir;
    if (target < 0 || target >= this.tabs.length) {
      return false;
    }
    this.onReorder(this.dragCurIdx, target);
    this.dragCurIdx = target;
    return true;
  }

  // Called continuously during a horizontal pan: as the dragged chip's residual
  // offset crosses ~0.6 of a chip width, swap it past the neighbour so the other
  // tabs re-flow live (with animation) under the finger.
  private onDragUpdate(offsetX: number): void {
    this.dragOffsetX = offsetX;
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

  // Drag lifecycle entry points, called from TabChip's PanGesture handlers.
  // The shared drag state lives here so every chip re-flows live during a drag
  // (each chip receives it as props and mirrors its translate/zIndex/scale).
  // NOTE: names avoid ArkUI's built-in onDragStart / onDragEnd / onMeasure
  // universal-attribute methods, which collide inside a @Component.
  private beginDrag(tabId: number): void {
    this.dragTabId = tabId;
    this.dragOffsetX = 0;
    this.dragSwaps = 0;
    this.dragUnit = this.avgChipWidth();
    this.dragCurIdx = this.tabs.findIndex((t: TabMeta) => t.id === tabId);
  }

  private endDrag(): void {
    this.dragTabId = -1;
    this.dragOffsetX = 0;
    this.dragSwaps = 0;
    this.dragCurIdx = -1;
  }

  private cancelDrag(): void {
    this.endDrag();
  }

  build() {
    // The right padding reserves room for the system window control buttons that
    // float at the top-right after the decoration bar is hidden, so our settings
    // button sits just to their left without overlapping.
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
        .onClick(() => { this.onOpenAbout(); })

      // Sidebar toggle
      Row() {
        Text(this.sidebarVisible ? '◧' : '◨')
          .fontSize(14)
          .fontColor(this.hoverSidebarToggle ? this.uiTheme.textDim : this.uiTheme.textFaint)
      }
      .width(24)
      .height(24)
      .margin({ left: 2, right: 4, top: 7 })
      .justifyContent(FlexAlign.Center)
      .borderRadius(5)
      .backgroundColor(this.hoverSidebarToggle ? this.uiTheme.pressOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((hover: boolean) => { this.hoverSidebarToggle = hover; })
      .onClick(() => { this.onToggleSidebar(); })

      if (!this.tabCompact) {
        // Non-compact: horizontal scroll, variable width chips
        Scroll(this.tabScroller) {
          Column() {
            Blank()
              .layoutWeight(1)
              .backgroundColor(Color.Transparent)

            Row({ space: 4 }) {
              ForEach(this.tabs, (tab: TabMeta) => {
                TabChip({
                  tab: tab,
                  isActive: tab.id === this.activeId,
                  themeBg: this.themeBg,
                  themeFg: this.themeFg,
                  fontSize: this.fontSize,
                  uiFontFamily: this.uiFontFamily,
                  tabCompact: this.tabCompact,
                  dragTabId: this.dragTabId,
                  dragOffsetX: this.dragOffsetX,
                  dragSwaps: this.dragSwaps,
                  dragUnit: this.dragUnit,
                  onSwitchTab: (id: number): void => { this.onSwitchTab(id); },
                  onCloseTab: (id: number): void => { this.onCloseTab(id); },
                  onRenameTab: (id: number): void => { this.onRenameTab(id); },
                  onCloseOthers: (id: number): void => { this.onCloseOthers(id); },
                  beginDrag: (id: number): void => { this.beginDrag(id); },
                  continueDrag: (x: number): void => { this.onDragUpdate(x); },
                  endDrag: (): void => { this.endDrag(); },
                  cancelDrag: (): void => { this.cancelDrag(); },
                  measureWidth: (w: number): void => { this.chipWidths.set(tab.id, w); }
                })
              }, (tab: TabMeta) => tab.id.toString())
            }
            // Futuristic: leave room on the left so the active capsule's glow
            // isn't clipped by the Scroll bounds.
            .padding({ left: this.uiTheme.accentGradient ? 8 : 0, right: 4 })
            .alignItems(VerticalAlign.Bottom)
          }
          .height(40)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Start)

        // "+" new tab — fixed outside scroll area, slightly below center
        Row() {
          Text('+')
            .fontSize(16)
            .fontColor(this.hoverAddTab ? this.uiTheme.textDim : this.uiTheme.textFaint)
            .animation({ duration: 120, curve: Curve.EaseOut })
        }
        .width(24)
        .height(24)
        .margin({ top: 4 })
        .justifyContent(FlexAlign.Center)
        .borderRadius(5)
        .backgroundColor(this.hoverAddTab ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverAddTab = h; })
        .onClick(() => { this.onNewTab(); })

        // Overflow menu button — shown only in non-compact mode
        Row() {
          Text('▼')
            .fontSize(9)
            .fontColor(this.hoverOverflow ? this.uiTheme.textDim : this.uiTheme.textFaint)
            .animation({ duration: 120, curve: Curve.EaseOut })
        }
        .width(24)
        .height(24)
        .margin({ top: 4 })
        .justifyContent(FlexAlign.Center)
        .borderRadius(5)
        .backgroundColor(this.hoverOverflow ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverOverflow = h; })
        .onClick(() => { this.onOpenOverflow(); })
      } else {
        // Compact: equal-width chips, no scroll, all tabs visible
        Row({ space: 4 }) {
          ForEach(this.tabs, (tab: TabMeta) => {
            TabChip({
              tab: tab,
              isActive: tab.id === this.activeId,
              themeBg: this.themeBg,
              themeFg: this.themeFg,
              fontSize: this.fontSize,
              uiFontFamily: this.uiFontFamily,
              tabCompact: this.tabCompact,
              dragTabId: this.dragTabId,
              dragOffsetX: this.dragOffsetX,
              dragSwaps: this.dragSwaps,
              dragUnit: this.dragUnit,
              onSwitchTab: (id: number): void => { this.onSwitchTab(id); },
              onCloseTab: (id: number): void => { this.onCloseTab(id); },
              onRenameTab: (id: number): void => { this.onRenameTab(id); },
              onCloseOthers: (id: number): void => { this.onCloseOthers(id); },
              beginDrag: (id: number): void => { this.beginDrag(id); },
              continueDrag: (x: number): void => { this.onDragUpdate(x); },
              endDrag: (): void => { this.endDrag(); },
              cancelDrag: (): void => { this.cancelDrag(); },
              measureWidth: (w: number): void => { this.chipWidths.set(tab.id, w); }
            })
          }, (tab: TabMeta) => tab.id.toString())
        }
        .height(40)
        .padding({ right: 4 })
        .alignItems(VerticalAlign.Bottom)
        .layoutWeight(1)

        // "+" new tab — fixed outside chip row, same position as non-compact
        Row() {
          Text('+')
            .fontSize(16)
            .fontColor(this.hoverAddTab ? this.uiTheme.textDim : this.uiTheme.textFaint)
            .animation({ duration: 120, curve: Curve.EaseOut })
        }
        .width(24)
        .height(24)
        .margin({ top: 4 })
        .justifyContent(FlexAlign.Center)
        .borderRadius(5)
        .backgroundColor(this.hoverAddTab ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverAddTab = h; })
        .onClick(() => { this.onNewTab(); })
      }

      // Guide help button — line-art circled "?" matching the system controls
      Row() {
        Row() {
          this.helpIcon()
        }
        .width(30)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .borderRadius(7)
        .backgroundColor(this.hoverGuide ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 150, curve: Curve.EaseOut })
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .focusable(false)
      .onHover((h: boolean) => { this.hoverGuide = h; })
      .onClick(() => { this.onOpenGuide(); })

      // Connection status capsule — left of the settings icon, only when the
      // page says the active tab is connected (showStatusCapsule).
      if (this.showStatusCapsule) {
        Row({ space: 5 }) {
          Circle({ width: 6, height: 6 }).fill(this.uiTheme.success)
          Text(this.statusText).fontSize(10.5).fontColor(this.uiTheme.success)
        }
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .backgroundColor(this.uiTheme.successBg)
        .border({ width: 1, color: this.uiTheme.successBorder })
        .borderRadius(RADIUS_PILL)
      }

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
        .backgroundColor(this.hoverSettings ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 150, curve: Curve.EaseOut })
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .focusable(false)
      .onHover((h: boolean) => { this.hoverSettings = h; })
      .onClick(() => { this.onOpenSettings(); })
    }
    .width('100%')
    .height(40)
    .padding({ right: 130 })
    .backgroundColor(this.uiTheme.bgChrome)
  }


  // Line-art help icon (hollow circle + "?") — same stroke weight / hover
  // behavior as the settings icon and the system caption buttons it sits beside.
  // Unified icon spec (Task 8): 18×18 viewport, 1.8 stroke, textDim → textPrimary on hover.
  @Builder
  private helpIcon() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: 16, height: 16 })
        .fill(Color.Transparent)
        .stroke(this.hoverGuide ? this.uiTheme.textPrimary : this.uiTheme.textDim)
        .strokeWidth(1.8)
      Text('?')
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.hoverGuide ? this.uiTheme.textPrimary : this.uiTheme.textDim)
    }
    .width(18)
    .height(18)
    .animation({ duration: 120, curve: Curve.EaseOut })
  }

  // Thin-line "sliders" icon, monochrome to match the system window-control
  // buttons (minimize / maximize / close) it sits beside: hollow knobs, no
  // fill, no accent color. Unified icon spec (Task 8): 14×14 viewport, 1.6
  // stroke, textDim → textPrimary on hover.
  @Builder
  private settingsIcon() {
    Column({ space: 5 }) {
      // top slider: knob on the right
      Stack({ alignContent: Alignment.Start }) {
        Row().width(14).height(1.6).borderRadius(0.8)
          .backgroundColor(this.hoverSettings ? this.uiTheme.textPrimary : this.uiTheme.textDim)
        Circle({ width: 4.5, height: 4.5 })
          .fill(this.uiTheme.bgSurface)
          .stroke(this.hoverSettings ? this.uiTheme.textPrimary : this.uiTheme.textDim)
          .strokeWidth(1.6)
          .margin({ left: 7 })
      }
      .width(14).height(4.5)

      // bottom slider: knob on the left
      Stack({ alignContent: Alignment.Start }) {
        Row().width(14).height(1.6).borderRadius(0.8)
          .backgroundColor(this.hoverSettings ? this.uiTheme.textPrimary : this.uiTheme.textDim)
        Circle({ width: 4.5, height: 4.5 })
          .fill(this.uiTheme.bgSurface)
          .stroke(this.hoverSettings ? this.uiTheme.textPrimary : this.uiTheme.textDim)
          .strokeWidth(1.6)
          .margin({ left: 2.5 })
      }
      .width(14).height(4.5)
    }
    .width(14)
    .height(14)
    .justifyContent(FlexAlign.Center)
    .animation({ duration: 120, curve: Curve.EaseOut })
  }
}

// Per-tab chip. Extracted from TabStrip's buildTabChip @Builder so the chip can
// observe its TabMeta via @ObjectLink: title/status updates re-render the chip
// in place instead of destroying + recreating it. The old ForEach key
// `id + '_' + title` rebuilt the chip on every title change, which also closed
// any open right-click context menu. Drag/hover state that chips must SHARE
// (drag reflow) stays in TabStrip and is passed down as props + callbacks;
// per-chip hover / click-vs-drag bookkeeping stays local here.
@Component
struct TabChip {
  @ObjectLink tab: TabMeta;
  @Prop isActive: boolean = false;
  @Prop themeBg: string = REFINED_DARK_THEME.bgBase;
  @Prop themeFg: string = REFINED_DARK_THEME.textPrimary;
  @Prop fontSize: number = DEFAULT_FONT_SIZE;
  @Prop uiFontFamily: string = DEFAULT_UI_FONT;
  @Prop tabCompact: boolean = false;
  // Shared drag state (owned by TabStrip so non-dragged chips re-flow live).
  @Prop dragTabId: number = -1;
  @Prop dragOffsetX: number = 0;
  @Prop dragSwaps: number = 0;
  @Prop dragUnit: number = 110;

  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  @State private hoverSelf: boolean = false;
  @State private hoverClose: boolean = false;
  @State private hoverMenuAction: string = '';
  private didDrag: boolean = false;
  private lastDragEnd: number = 0;

  onSwitchTab: (id: number) => void = (_id: number) => {};
  onCloseTab: (id: number) => void = (_id: number) => {};
  onRenameTab: (id: number) => void = (_id: number) => {};
  onCloseOthers: (id: number) => void = (_id: number) => {};
  // Drag / measure callbacks are named to avoid ArkUI's built-in universal
  // attribute methods (onDragStart / onDragEnd / onMeasure) which collide with
  // @Component member names.
  beginDrag: (id: number) => void = (_id: number) => {};
  continueDrag: (offsetX: number) => void = (_x: number) => {};
  endDrag: () => void = () => {};
  cancelDrag: () => void = () => {};
  measureWidth: (width: number) => void = (_w: number) => {};

  build() {
    Row({ space: 6 }) {
      Text(this.tab.title)
        .fontSize(Math.max(10, this.fontSize - 1))
        .fontFamily(this.uiFontFamily)
        // Futuristic: capsule chip floats on the strip, so it uses chrome text
        // colors; refined: chip merges with the terminal card, so it uses the
        // terminal theme's fg (themeFg).
        .fontColor(this.isActive
          ? (this.uiTheme.accentGradient ? this.uiTheme.textPrimary : this.themeFg)
          : this.uiTheme.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(this.tabCompact ? 1 : 0)
      // ✕ turns red on hover to signal "this will close"; rests at 0.6 opacity
      Text('✕')
        .fontSize(11)
        .fontColor(this.hoverClose ? this.uiTheme.danger
          : (this.isActive
            ? (this.uiTheme.accentGradient ? this.uiTheme.textPrimary : this.themeFg)
            : this.uiTheme.textDim))
        .opacity(this.hoverClose ? 1.0 : 0.6)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverClose = h; })
        .onClick(() => { this.onCloseTab(this.tab.id); })
    }
    .height(this.isActive ? (this.uiTheme.accentGradient ? 28 : 32) : 26)
    // Futuristic lifts chips off the strip baseline so the capsule and its
    // glow read as a floating element; refined keeps chips flush (merged look).
    .margin({ bottom: this.uiTheme.accentGradient ? 6 : 0 })
    .layoutWeight(this.tabCompact ? 1 : 0)
    .padding({ left: 12, right: 10 })
    .borderRadius(this.isActive
      ? (this.uiTheme.accentGradient
        ? { topLeft: 14, topRight: 14, bottomLeft: 14, bottomRight: 14 } as BorderRadiuses
        : { topLeft: 9, topRight: 9, bottomLeft: 0, bottomRight: 0 } as BorderRadiuses)
      : (this.uiTheme.accentGradient
        ? { topLeft: 13, topRight: 13, bottomLeft: 13, bottomRight: 13 } as BorderRadiuses
        : { topLeft: 7, topRight: 7, bottomLeft: 7, bottomRight: 7 } as BorderRadiuses))
    // Inactive tab gets a subtle highlight on hover. Active tab: futuristic uses
    // the elevated chrome surface (floating capsule); refined merges with the
    // terminal background (themeBg) as before.
    .backgroundColor(this.isActive
      ? (this.uiTheme.accentGradient ? this.uiTheme.bgElevated : this.themeBg)
      : (this.hoverSelf ? this.uiTheme.pressOverlay : Color.Transparent))
    // Active chip outline: futuristic only (part of the floating capsule look).
    // Refined keeps the original seamless merge with the terminal background —
    // no ring. The accent glow shadow below stays fully transparent in refined.
    .border(this.isActive && this.uiTheme.accentGradient
      ? { width: 1, color: this.uiTheme.borderStrong }
      : { width: 0, color: Color.Transparent })
    // The dragged chip follows the finger via a residual X translate; the other
    // chips re-flow live (with animation) as the array is spliced mid-drag. The
    // chip never leaves the tab baseline (y is always 0).
    .translate({ x: this.dragTabId === this.tab.id ? (this.dragOffsetX - this.dragSwaps * this.dragUnit) : 0, y: 0 })
    .zIndex(this.dragTabId === this.tab.id ? 10 : 0)
    .scale(this.dragTabId === this.tab.id ? { x: 1.04, y: 1.04 } : { x: 1.0, y: 1.0 })
    // Drag shadow wins while dragging; otherwise the active chip carries the
    // scheme glow (transparent in refined), inactive chips none.
    .shadow(this.dragTabId === this.tab.id
      ? { radius: 12, color: this.uiTheme.shadowCard, offsetX: 0, offsetY: 2 }
      : (this.isActive
        ? { radius: 14, color: this.uiTheme.glowAccent, offsetX: 0, offsetY: 0 }
        : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 }))
    .animation(this.dragTabId === this.tab.id
      ? { duration: 0 }          // dragged chip tracks the finger with no lag
      : { duration: 180, curve: Curve.Friction })
    .alignItems(VerticalAlign.Center)
    .focusable(false)
    // Measure width so live-reorder thresholds match the real chip sizes.
    .onAreaChange((_o: Area, n: Area) => { this.measureWidth(Number(n.width)); })
    .onHover((h: boolean) => { this.hoverSelf = h; })
    .onClick(() => {
      // Ignore the click that fires right after a real drag; later taps work.
      if (Date.now() - this.lastDragEnd > 250) {
        this.onSwitchTab(this.tab.id);
      }
    })
    .bindContextMenu(this.buildContextMenu(), ResponseType.RightClick)
    // Whole-chip horizontal PanGesture for drag-to-reorder. priorityGesture
    // wins over the parent Scroll's horizontal scroll.
    .priorityGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 5 })
        .onActionStart(() => {
          this.didDrag = false;
          this.beginDrag(this.tab.id);
        })
        .onActionUpdate((e: GestureEvent) => {
          if (Math.abs(e.offsetX) > 4) {
            this.didDrag = true;
          }
          this.continueDrag(e.offsetX);
        })
        .onActionEnd(() => {
          if (this.didDrag) {
            this.lastDragEnd = Date.now();
          }
          this.endDrag();
        })
        .onActionCancel(() => {
          if (this.didDrag) {
            this.lastDragEnd = Date.now();
          }
          this.cancelDrag();
        })
    )
  }

  @Builder
  private buildContextMenu() {
    Column() {
      // 重命名
      Row({ space: 8 }) {
        Text('✎')
          .fontSize(12)
          .fontColor(this.uiTheme.textDim)
        Text('重命名')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'rename' ? this.uiTheme.hoverOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'rename' : ''; })
      .onClick(() => {
        // Reset the hover highlight here — the page used to clear it when the
        // rename sheet closed; the menu is already dismissed by then.
        this.hoverMenuAction = '';
        this.onRenameTab(this.tab.id);
      })

      // Separator with horizontal margins
      Divider().color(this.uiTheme.border).width('100%').margin({ left: 8, right: 8 })

      // 关闭其他
      Row({ space: 8 }) {
        Text('✕')
          .fontSize(12)
          .fontColor(this.uiTheme.textDim)
        Text('关闭其他标签页')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'close_others' ? this.uiTheme.warnBg : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'close_others' : ''; })
      .onClick(() => { this.onCloseOthers(this.tab.id); })

      // Separator
      Divider().color(this.uiTheme.border).width('100%').margin({ left: 8, right: 8 })

      // 关闭
      Row({ space: 8 }) {
        Text('✕')
          .fontSize(12)
          .fontColor(this.uiTheme.textDim)
        Text('关闭')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'close' ? this.uiTheme.dangerBg : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'close' : ''; })
      .onClick(() => { this.onCloseTab(this.tab.id); })
    }
    .width(160)
    .padding(4)
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CONTROL)
    .border({ width: 1, color: this.uiTheme.border })
    .shadow({ radius: 12, color: this.uiTheme.shadowCard, offsetY: 6 })
  }
}
