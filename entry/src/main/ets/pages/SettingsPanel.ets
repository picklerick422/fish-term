import { TerminalController } from 'libghostty_ohos';
import { UiTheme, REFINED_DARK_THEME, RADIUS_CONTROL, RADIUS_SHEET } from '../theme/UiTheme';
import { ConnectionStore } from '../store/ConnectionStore';
import {
  DEFAULT_FONT_SCALE_BOOST, DEFAULT_CJK_VERTICAL_OFFSET, DEFAULT_CHARACTER_SPACING
} from '../theme/FontScale';
import { common } from '@kit.AbilityKit';
import { CrashHistoryPage } from './CrashHistoryPage';
import { CrashStore } from '../crash/CrashStore';
import { CrashLogEntry } from '../crash/CrashTypes';
import { AppearanceSettings } from '../settings/AppearanceSettings';
import { TerminalSettings } from '../settings/TerminalSettings';
import { ShortcutsSettings } from '../settings/ShortcutsSettings';
import { AboutSettings } from '../settings/AboutSettings';
import { NotificationSettings } from '../settings/NotificationSettings';

@Component
export struct SettingsPanel {
  controller: TerminalController = new TerminalController();
  store: ConnectionStore | null = null;
  @Prop fontSize: number = 16;
  @Prop lineSpacing: number = 1.05;
  @Prop initialTab: number = 0;
  @Prop statusText: string = '空闲';
  @Prop statusColor: string = REFINED_DARK_THEME.textDim;
  @Prop hostLabel: string = '';
  @Prop token: string = '';
  onTokenChange: (token: string) => void = (_token: string) => {};
  @Prop themeName: string = '';
  @Prop cursorStyle: number = 0;
  @Prop cursorBlink: boolean = true;
  @Prop scrollbackLines: number = 20000;
  onThemeChange: (name: string) => void = (_name: string) => {};
  onCursorStyleChange: (v: number) => void = (_v: number) => {};
  onCursorBlinkChange: (v: boolean) => void = (_v: boolean) => {};
  onScrollbackChange: (v: number) => void = (_v: number) => {};
  onFontSizeChange: (size: number) => void = (_size: number) => {};
  onLineSpacingChange: (spacing: number) => void = (_spacing: number) => {};
  @Prop uiFontFamily: string = 'Inter';
  @Prop termFontFamily: string = '';
  onUIFontFamilyChange: (family: string) => void = (_family: string) => {};
  onTermFontFamilyChange: (family: string) => void = (_family: string) => {};
  @Prop fontScaleBoost: number = DEFAULT_FONT_SCALE_BOOST;
  @Prop cjkVerticalOffset: number = DEFAULT_CJK_VERTICAL_OFFSET;
  @Prop characterSpacing: number = DEFAULT_CHARACTER_SPACING;
  onFontScaleBoostChange: (v: number) => void = (_v: number) => {};
  onCjkVerticalOffsetChange: (v: number) => void = (_v: number) => {};
  onCharacterSpacingChange: (v: number) => void = (_v: number) => {};
  @Prop tabCompact: boolean = false;
  onTabCompactChange: (v: boolean) => void = (_v: boolean) => {};
  @Prop notifyEnabled: boolean = true;
  @Prop notifyCompleted: boolean = true;
  @Prop notifyAwaiting: boolean = true;
  @Prop notifyBackgroundOnly: boolean = true;
  onNotifyEnabledChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyCompletedChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyAwaitingChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyBackgroundOnlyChange: (v: boolean) => void = (_v: boolean) => {};
  onTestNotification: (slotType: number, contentType: number, title: string, text: string) => void = (_s: number, _c: number, _t: string, _x: string) => {};
  onReplayGuide: () => void = () => {};
  onClose: () => void = () => {};

  @State private tab: number = 0;
  @State private hoverBack: boolean = false;
  @State private hoverTabIdx: number = -1;
  @State private showCrashHistory: boolean = false;
  @State private crashEntries: CrashLogEntry[] = [];
  private crashStore: CrashStore | null = null;
  // Drives the native horizontal slide between sub-pages.
  private subTabs: TabsController = new TabsController();
  // Drives the slide between settings and crash-history page.
  private pageTabs: TabsController = new TabsController();
  // Font-dropdown open state is shared with AppearanceSettings via @Link so a
  // tap anywhere on the panel background still dismisses an open dropdown.
  @State private uiFontDropdownOpen: boolean = false;
  @State private termFontDropdownOpen: boolean = false;
  // Theme count shown on the About page (the theme list itself lives in
  // AppearanceSettings).
  @State private themeCount: number = 0;
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  aboutToAppear(): void {
    this.tab = this.initialTab;
    this.themeCount = this.controller.getThemeList().length;
  }

  // 加载崩溃列表并切换到崩溃历史页
  private openCrashHistory(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx) {
        this.crashStore = new CrashStore(ctx as common.UIAbilityContext);
        this.crashEntries = this.crashStore.listEntries();
        this.showCrashHistory = true;
        this.pageTabs.changeIndex(1);
      }
    } catch (_e) {
      // fail silently
    }
  }

  build() {
    Column() {
      Tabs({ controller: this.pageTabs, index: this.showCrashHistory ? 1 : 0 }) {
        TabContent() {
          Column() {
      if (!this.showCrashHistory) {
        // Header: ← + left-aligned title, with the connection status on the right.
        Row() {
        Row() {
          Text('←')
            .fontSize(18)
            .fontColor(this.uiTheme.textDim)
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .borderRadius(RADIUS_CONTROL)
        .backgroundColor(this.hoverBack ? this.uiTheme.pressOverlay : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverBack = h; })
        .onClick(() => { this.onClose(); })

        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)

        // connection status, pushed to the right
        Row({ space: 6 }) {
          Text('●')
            .fontSize(9)
            .fontColor(this.statusColor)
          Text(this.statusText)
            .fontSize(12)
            .fontColor(this.uiTheme.textDim)
          Text(this.hostLabel)
            .fontSize(12)
            .fontColor(this.uiTheme.textDim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
        .padding({ right: 8 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })

      // Tab row (fixed under the header)
      Row({ space: 6 }) {
        this.buildTabButton('外观', 0)
        this.buildTabButton('终端', 1)
        this.buildTabButton('快捷键', 2)
        this.buildTabButton('关于', 3)
        this.buildTabButton('通知', 4)
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })

      // Body: native Tabs gives a smooth horizontal slide between sub-pages.
      // The native bar is hidden (barHeight 0); our pill row above drives it
      // via subTabs.changeIndex(). Each page scrolls independently.
      Tabs({ controller: this.subTabs, index: this.tab }) {
        TabContent() { this.settingsPage(0) }
        TabContent() { this.settingsPage(1) }
        TabContent() { this.settingsPage(2) }
        TabContent() { this.settingsPage(3) }
        TabContent() { this.settingsPage(4) }
      }
      .barHeight(0)
      .scrollable(false)
      .animationDuration(280)
      .layoutWeight(1)
      .onChange((i: number) => { this.tab = i; })
      } // end if (!this.showCrashHistory)
          }
          .width('100%')
          .height('100%')
        }
        TabContent() {
          if (this.showCrashHistory) {
            CrashHistoryPage({
              entries: this.crashEntries,
              onBack: () => { this.showCrashHistory = false; this.pageTabs.changeIndex(0); },
              onDeleteAll: () => { this.crashEntries = []; },
              store: this.crashStore!
            })
          }
        }
      }
      .barHeight(0)
      .scrollable(false)
      .animationDuration(280)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    // Unified sheet shell (Task 8): bgSurface card + sheet radius + 1px border + shadow.
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_SHEET)
    .border({ width: 1, color: this.uiTheme.border })
    .shadow({ radius: 32, color: this.uiTheme.shadowCard, offsetX: 0, offsetY: 8 })
    .onClick(() => {
      if (this.uiFontDropdownOpen || this.termFontDropdownOpen) {
        this.uiFontDropdownOpen = false;
        this.termFontDropdownOpen = false;
      }
    })
  }

  @Builder
  private buildTabButton(label: string, index: number) {
    Text(label)
      .fontSize(12)
      .fontFamily(this.uiFontFamily)
      .fontColor(this.tab === index ? this.uiTheme.textOnAccent : this.uiTheme.textDim)
      .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      // All three pill states expressed as gradient stops so a single
      // linearGradient replaces backgroundColor: active uses the degenerate
      // accent gradient (solid under refined), hover/base stay as before.
      .linearGradient({
        angle: 90,
        colors: this.tab === index
          ? (this.uiTheme.accentGradient
            ? [[this.uiTheme.accent, 0.0], [this.uiTheme.accentAlt, 1.0]]
            : [[this.uiTheme.accent, 0.0], [this.uiTheme.accent, 1.0]])
          : (this.hoverTabIdx === index
            ? [[this.uiTheme.pressOverlay, 0.0], [this.uiTheme.pressOverlay, 1.0]]
            : [[Color.Transparent, 0.0], [Color.Transparent, 1.0]])
      })
      .borderRadius(20)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverTabIdx = h ? index : -1; })
      .onClick(() => {
        // Only drive the controller — setting this.tab here would make the
        // Tabs `index` binding jump instantly and skip the slide animation.
        // onChange() updates this.tab once the slide starts.
        if (index !== this.tab) {
          this.subTabs.changeIndex(index);
        }
      })
  }

  // One settings sub-page: each scrolls independently inside its TabContent.
  @Builder
  private settingsPage(t: number) {
    Scroll() {
      Column({ space: 16 }) {
        if (t === 0) {
          AppearanceSettings({
            controller: this.controller,
            store: this.store,
            fontSize: this.fontSize,
            lineSpacing: this.lineSpacing,
            uiFontFamily: this.uiFontFamily,
            termFontFamily: this.termFontFamily,
            fontScaleBoost: this.fontScaleBoost,
            cjkVerticalOffset: this.cjkVerticalOffset,
            characterSpacing: this.characterSpacing,
            themeName: this.themeName,
            cursorStyle: this.cursorStyle,
            cursorBlink: this.cursorBlink,
            scrollbackLines: this.scrollbackLines,
            uiFontDropdownOpen: this.uiFontDropdownOpen,
            termFontDropdownOpen: this.termFontDropdownOpen,
            onFontSizeChange: (size: number): void => { this.onFontSizeChange(size); },
            onLineSpacingChange: (spacing: number): void => { this.onLineSpacingChange(spacing); },
            onUIFontFamilyChange: (family: string): void => { this.onUIFontFamilyChange(family); },
            onTermFontFamilyChange: (family: string): void => { this.onTermFontFamilyChange(family); },
            onFontScaleBoostChange: (v: number): void => { this.onFontScaleBoostChange(v); },
            onCjkVerticalOffsetChange: (v: number): void => { this.onCjkVerticalOffsetChange(v); },
            onCharacterSpacingChange: (v: number): void => { this.onCharacterSpacingChange(v); },
            onThemeChange: (name: string): void => { this.onThemeChange(name); },
            onCursorStyleChange: (v: number): void => { this.onCursorStyleChange(v); },
            onCursorBlinkChange: (v: boolean): void => { this.onCursorBlinkChange(v); }
          })
        } else if (t === 1) {
          TerminalSettings({
            controller: this.controller,
            store: this.store,
            token: this.token,
            hostLabel: this.hostLabel,
            cursorStyle: this.cursorStyle,
            cursorBlink: this.cursorBlink,
            scrollbackLines: this.scrollbackLines,
            tabCompact: this.tabCompact,
            uiFontFamily: this.uiFontFamily,
            onTokenChange: (token: string): void => { this.onTokenChange(token); },
            onScrollbackChange: (v: number): void => { this.onScrollbackChange(v); },
            onTabCompactChange: (v: boolean): void => { this.onTabCompactChange(v); }
          })
        } else if (t === 2) {
          ShortcutsSettings({
            uiFontFamily: this.uiFontFamily
          })
        } else if (t === 3) {
          AboutSettings({
            uiFontFamily: this.uiFontFamily,
            themeCount: this.themeCount,
            onReplayGuide: (): void => { this.onReplayGuide(); },
            onOpenCrashHistory: (): void => { this.openCrashHistory(); }
          })
        } else if (t === 4) {
          NotificationSettings({
            uiFontFamily: this.uiFontFamily,
            notifyEnabled: this.notifyEnabled,
            notifyCompleted: this.notifyCompleted,
            notifyAwaiting: this.notifyAwaiting,
            notifyBackgroundOnly: this.notifyBackgroundOnly,
            onNotifyEnabledChange: (v: boolean): void => { this.onNotifyEnabledChange(v); },
            onNotifyCompletedChange: (v: boolean): void => { this.onNotifyCompletedChange(v); },
            onNotifyAwaitingChange: (v: boolean): void => { this.onNotifyAwaitingChange(v); },
            onNotifyBackgroundOnlyChange: (v: boolean): void => { this.onNotifyBackgroundOnlyChange(v); },
            onTestNotification: (s: number, c: number, title: string, text: string): void => {
              this.onTestNotification(s, c, title, text);
            }
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}
